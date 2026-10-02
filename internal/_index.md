---
title: Internal
# `type: blog` points this section at Hextra's blog layouts, so it gets the real
# thing - post cards, the identity rail, tags, reading time, pagination - rather
# than the plain `_default` list a new section would otherwise use.
#
# Nothing here is ever published. These files live outside content/ and are mounted
# in only by config/development/hugo.yaml, so a production build or server never
# sees them: there is no page to leak into the rendered output, the flexsearch
# index, llms.txt, the feeds or the sitemap.
#
# Not `draft: true`, and not `ignoreFiles`: --buildDrafts publishes a draft, and
# ignoreFiles is honoured by `hugo` but silently ignored by `hugo server`, so
# `make preview` served this section while the build excluded it.
cascade:
  type: blog
  comments: false
# The navbar entry is declared HERE rather than in config, because a config-level
# `menu.main` REPLACES the whole menu instead of adding to it - Hugo replaces
# slices when merging configuration, so an environment-specific menu file wipes
# Docs, Blog and About. A front matter entry is additive, and it exists only when
# the page does: in a production build this section is not mounted, so the entry
# cannot appear and cannot 404.
menus:
  main:
    name: Internal
    weight: 5
---
