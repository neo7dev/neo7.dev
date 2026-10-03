---
title: "Fine-tuning a voice with Coqui TTS"
date: 2026-10-03T18:10:00+05:30
authors:
  - name: neo7.dev
tags:
  - machine-learning
  - audio
excludeSearch: false
summary: "Cloning a voice is mostly dataset work. The training run is a day of GPU time and three flags; getting twenty usable minutes of audio out of a recording is the part that decides how it sounds."
# `coverText` renders in the card cover slot with the prompt glyph from
# params.command.prompt until there is a real cover image.
coverText: |
  coquitts --finetune
---

{{< lead >}}
Try zero-shot cloning first; it is free and may be enough. If you do fine-tune, the
result is decided by twenty minutes of clean, correctly transcribed audio,
`--restore_path` is the flag you want and `--continue_path` is not, and the alignment
plot tells you more than the loss curve.
{{< /lead >}}

<!--more-->

Fine-tuning a text-to-speech model on a single voice is not a modelling problem.
The architectures are published, the checkpoints are downloadable, and the
training command is three flags long. What decides whether the result is usable
is the twenty minutes of audio you feed it and how carefully they were prepared.

{{< callout type="info" >}}
The original Coqui TTS project was wound up and its repository archived. The
code lives on as a community-maintained fork, which is what the package name on
PyPI resolves to now. Pin a version — the configuration schema has moved
between releases and a config written for one is not guaranteed to load in
another.
{{< /callout >}}

## Try zero-shot before you train anything

Before committing a day of GPU time: YourTTS can clone a voice _without
training_. It takes a reference clip of a few seconds, derives a speaker
embedding from it, and synthesises in that voice immediately.

```shell
tts --list_models
tts --model_name "tts_models/multilingual/multi-dataset/your_tts" \
    --text "A sentence in the cloned voice." \
    --speaker_wav reference.wav \
    --language_idx en \
    --out_path out.wav
```

For a lot of uses that is the whole job. Zero-shot output is recognisably the
target voice, it costs nothing to try, and it establishes the baseline that
fine-tuning has to beat.

Fine-tune when zero-shot is not enough: when prosody is wrong, when the voice
drifts across long passages, when the accent is one the base model never saw, or
when you need consistent output across hundreds of clips rather than a
convincing few seconds.

## The dataset is the work

Target roughly twenty minutes of clean speech from one speaker, split into
utterances of a few seconds each. Twenty minutes is where fine-tuning starts
producing something worth listening to; an hour is noticeably better; three hours
has diminishing returns against the effort of cleaning them.

**Record or source it consistently.** One microphone, one room, one session if
possible. A model trained on two acoustic environments learns both and blends
them, and the blend sounds like neither.

**Denoise.** Room tone, hum, and air conditioning are learned as part of the
voice — the model will reproduce them, because from its perspective they are a
feature of the speaker. An RNN-based noise suppressor handles this well and is
cheap to run over a whole corpus. Listen to the output afterwards; aggressive
suppression leaves artefacts on sibilants that are worse than the noise.

**Transcribe with a speech recognition model, then correct it.** Whisper is the
obvious choice and its transcripts are good enough to use as a starting point.
They are not good enough to use unread: numbers come out as digits where the
speaker said words, punctuation is inconsistent, and disfluencies are silently
dropped. Every mismatch between transcript and audio is a training example
teaching the model the wrong mapping.

**Segment on silence, not on a fixed length.** Utterances should begin and end at
natural boundaries, with a short margin of silence trimmed to something uniform.
Clips that cut mid-word teach the model to cut mid-word.

**Normalise the format.** One sample rate, mono, consistent loudness. The sample
rate has to match what the pretrained checkpoint's config expects — resampling at
training time is not automatic, and a mismatch produces output that is correct
but at the wrong speed, which is a confusing way to lose an afternoon.

The conventional layout is the LJSpeech one, because every formatter supports it:

```text
dataset/
  metadata.csv
  wavs/
    utt_0001.wav
    utt_0002.wav
```

`metadata.csv` is pipe-separated: identifier, raw transcript, normalised
transcript. The identifier matches the filename without its extension.

## Fine-tuning VITS from a pretrained checkpoint

VITS is end-to-end — text to waveform in one model, no separate vocoder. That
makes it the simplest thing to fine-tune, because there is only one training run.

The approach is to take a multi-speaker checkpoint that has already learned
roughly a million steps' worth of general speech, and continue training it on the
new speaker:

1. Download a pretrained multi-speaker VITS checkpoint and its config.
2. Copy the config and edit it: point the dataset path and formatter at your
   corpus, set the output path, set the batch size to what the GPU will hold.
3. Start training with `--restore_path` pointing at the checkpoint.

```shell
python TTS/bin/train_tts.py \
  --config_path config.json \
  --restore_path /path/to/pretrained/model_file.pth
```

{{< callout type="warning" >}}
`--restore_path` and `--continue_path` are not the same flag.
`--restore_path` loads weights and starts a **new** run with the step counter
at zero — what you want for fine-tuning. `--continue_path` resumes an existing
run, keeping its optimiser state and step count. Using the wrong one either
throws away your progress or fails to apply the new dataset.
{{< /callout >}}

Expect the first recognisable output within a few thousand steps and something
worth shipping somewhere around fifty thousand. Watch the attention alignment in
the training dashboard rather than the loss number: a model whose alignment plot
is a clean diagonal is learning the mapping, and one whose alignment is diffuse
will produce audio that skips or repeats words no matter how low the loss goes.

Synthesise test sentences every few thousand steps. Loss is a poor proxy for
whether a voice sounds right, and listening is the only evaluation that matters.

## Fine-tuning YourTTS

YourTTS is VITS extended for multilingual, multi-speaker, zero-shot synthesis.
Fine-tuning it is the same shape with one extra concern: speaker conditioning.

The model takes a speaker embedding alongside the text. Those embeddings come
from a separate speaker-encoder model and have to be computed for your dataset
before training — the pipeline includes a script for this, and the resulting file
is referenced from the config. Skip it and training starts, conditions on
nothing useful, and produces an averaged voice.

The flag worth understanding is the speaker consistency loss. It adds a term
penalising the distance between the speaker embedding of the generated audio and
that of the reference, with `speaker_encoder_loss_alpha` controlling its weight.

The intuition is that it should improve speaker similarity. In practice the
published results are mixed: it improves similarity on some datasets and costs
audio quality on others, and the original paper's own ablation does not land
clearly in its favour. Treat it as a knob to test on your own data rather than a
setting to copy — train with it off first, since that is the cheaper baseline, and
only reach for it if similarity is the thing you are short of.

{{< callout type="warning" >}}
YourTTS fine-tuning is the least documented path here. The examples in
circulation are mostly from community discussion threads rather than the
project's own documentation, several of them target configuration schemas that
have since changed, and some contradict each other. Budget time for reading the
training code to work out what a config key actually does.
{{< /callout >}}

## Before you clone anyone

A voice is identifying. Cloning one you do not own needs the speaker's informed
consent, and in a growing number of jurisdictions that is a legal requirement
rather than an etiquette one. Synthesised speech also needs to be labelled as
such wherever it could be mistaken for a recording — the whole point of a good
fine-tune is that listeners cannot tell, which is exactly why they have to be
told.
