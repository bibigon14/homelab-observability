# A cache rule pinned to the old hostname made Grafana look broken after a rename

**Date**: 2026-09-29
**Time to root cause**: ~45 minutes
**Severity**: public dashboards inaccessible for the duration
**Author**: Dmitry Stepanov

## Summary

`grafana.dstepanov.dev` started returning the "Grafana has failed to load
its application files" fallback page. The Grafana process was healthy and
every JS bundle returned HTTP 200, but the bytes on the wire were not the
bytes on disk - same length, different hash, a browser-side `SyntaxError`
on line 109.

The cause was a Cloudflare Cache Rule pinned to
`grafana.sre.dstepanov.dev`, the previous public hostname. The rule
bypassed cache for asset requests. When the site moved to
`grafana.dstepanov.dev` a few days earlier, DNS and origin config moved
with it and nobody moved the Cache Rule. Requests to the new hostname
started hitting the cache normally, and something in the cache path was
rewriting the JS in flight.

Most of the 45 minutes was spent chasing edge features - Rocket Loader,
Email Obfuscation, Auto Minify - and only stopped once the rule one
hostname string away from correct got opened directly.

## Timeline

- **06:15** Loaded `grafana.dstepanov.dev`, got the fallback error page.
  Browser console: `Uncaught SyntaxError: Invalid or unexpected token` at
  `js:109:17426`.

- **06:22** Grafana health OK on the Pi. Noticed `root_url` in
  `/etc/grafana/grafana.ini` still pointed at `grafana.sre.dstepanov.dev`
  from the pre-rename state and fixed it via `sed`, restarted
  `grafana-server`. `appUrl` in the API now correct. Unrelated to the
  actual failure - error page still there.

- **06:31** Compared the failing bundle byte-for-byte:

      # on Pi
      md5sum /usr/share/grafana/public/build/7606.e8e4d98948a4bb1cf3bc.js
      259c3e509931652fd82452b1af7b3710
      # over the wire
      curl -s https://grafana.dstepanov.dev/public/build/7606.e8e4d98948a4bb1cf3bc.js | md5sum
      ca1ac6ba1a9fbcbf4358cf0b2e5cb1e3

  Same length (4112991 bytes), first byte diff at 737345 - lines up with
  the browser's line 109 error. Something in Cloudflare's pipeline was
  mutating bytes in place.

- **06:38** Guessed Rocket Loader - already OFF at the zone. Guessed
  Email Obfuscation (Grafana bundles contain `@`-addresses that could get
  wrapped in a JS decoder). Started navigating to Security → Settings.

- **06:44** Enabled Development Mode as a diagnostic. Bundle hash
  immediately matched local. Read this as "definitely edge features."

- **06:52** Started drafting a permanent Configuration Rule for the
  hostname to disable Email Obfuscation, Rocket Loader, Auto Minify. Went
  to Rules → Configuration Rules to build it.

- **06:57** Rules → **Cache Rules** had an existing rule with
  `Hostname equals grafana.sre.dstepanov.dev` and `Bypass cache`. Edited
  the hostname to `grafana.dstepanov.dev`. Grafana loaded on refresh.

- **07:00** Turned Dev Mode off. Bundle hash on the wire stayed at
  `259c3e509931652fd82452b1af7b3710`. Fixed in the right place.

## Why it took 45 minutes

**The rename was mentally filed as complete.** `grafana.sre` → `grafana`
had been done days earlier. DNS moved, origin config moved, admin-signed
sessions worked. The Cache Rule left behind was the last thing on the
suspect list because the migration itself was not on the suspect list.

**"Bytes rewritten in transit" collapsed into "edge feature".** Cloudflare
has more than one class of thing that touches a response body. Cache Rules
control whether it goes through the cache pipeline at all; Configuration
Rules control which optimizations run on it. I jumped from "Cloudflare is
mutating this" to "edge features are mutating this" and skipped the branch
where the cache path itself was the problem.

**Development Mode was a two-variable experiment.** Enabling Dev Mode
disables caching AND edge transformations simultaneously. When the hash
matched local, that was equally consistent with either theory - but I had
already picked one. A smaller test (purge cache alone, wait, refetch)
would have split them apart in one step.

**Sidebar geography shaped hypothesis order.** Speed → Optimization has
Rocket Loader; Security → Settings has Email Obfuscation. Rules → Cache
Rules was three clicks away and never came up until it got opened
directly. Once a theory picks its sidebar section, the surrounding
features start looking like plausible next guesses.

## Fix

Cache Rule edited in place - `Value` field changed from
`grafana.sre.dstepanov.dev` to `grafana.dstepanov.dev`. `Bypass cache`
action unchanged. No new rule created.

Development Mode disabled immediately after. Bundle hash stable across
repeated refetches:

    for i in 1 2 3; do
      sleep 30
      curl -s https://grafana.dstepanov.dev/public/build/7606.e8e4d98948a4bb1cf3bc.js | md5sum
    done
    259c3e509931652fd82452b1af7b3710  -
    259c3e509931652fd82452b1af7b3710  -
    259c3e509931652fd82452b1af7b3710  -

Which specific Cloudflare transformer was rewriting bytes when the cache
path was engaged is still unknown and did not need to be answered - the
bypass restores the behavior the URL had all along on the old hostname.
Likely Auto Minify JS (deprecated in the dashboard but still applied on
free-plan zones), possibly a cache-layer optimization not exposed as its
own toggle. Either way, the fix is the same one that had already existed
for months.

## What to do differently

**Hostname migrations need a checklist that covers every layer that
stores a hostname.** DNS is the visible one. Under it on a single
Cloudflare zone: Cache Rules, Configuration Rules, Page Rules (legacy),
Workers routes, WAF/Firewall rules, Transform rules, Redirect rules,
Custom Rules, Bot management overrides, Access policies. Any one of them,
pinned to the old name, is a future outage waiting for the right request.
Next rename runs a grep for the old hostname across an exported zone
config before declaring the move done.

**Diagnostic experiments should change one variable.** Dev Mode was fast
and made the problem visibly go away, which felt like an answer. It was
not - it moved two independent knobs at once. A one-knob equivalent
(purge cache, or add a temporary Bypass rule for the new hostname) would
have pointed at the caching path directly.

**Small per-hostname workarounds are still production infrastructure.**
The Bypass rule was one line, added long enough ago that its purpose was
forgotten. It broke silently at the rename because it was pinned to an
FQDN the site no longer used. Anything else that lives on a specific
hostname - a Configuration Rule, a Worker route, an Access policy - has
the same failure mode.
