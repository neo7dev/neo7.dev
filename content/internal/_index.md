---
title: Internal
# `type: blog` points this section at Hextra's blog layouts, so it gets the real
# thing - post cards, the identity rail, tags, reading time, pagination - rather
# than the plain `_default` list a new section would otherwise use.
#
# Nothing here is ever published. `config/production/hugo.yaml` drops `internal/**`
# from the content mount, so in a production build Hugo does not read these files
# at all: there is no page to leak into the search index, llms.txt, the RSS feeds
# or the sitemap. `hugo server` defaults to the development environment and `hugo`
# to production, so `make dev` shows this section and `make prod`, `make preview`
# and CI cannot.
cascade:
  type: blog
  comments: false
---

Notes that are useful to keep and not to publish: setup records, runbooks, and
anything naming real hosts or paths.
