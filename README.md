# SerpGuard

[![CI](https://github.com/Divyanshu-2907/SerpGuard/actions/workflows/ci.yml/badge.svg)](https://github.com/Divyanshu-2907/SerpGuard/actions/workflows/ci.yml)

**Fact-checks AI-generated text and code against live search results.**

Built for the SerpApi India Hackathon 2026 — AI Agents track.

---

## What it does, and why

Language models produce claims that read exactly like facts whether or not they are: a version
number that shipped a year later than stated, a method that does not exist, a statistic that was
true in 2021. SerpGuard takes a block of AI-generated prose or code, uses Claude to pull out the
discrete claims that can actually be checked, runs a real Google search per claim through SerpApi,
and then asks Claude to rule on each claim **against the returned snippets only** — returning
`verified`, `unconfirmed` or `contradicted` with a one-line reason and a source URL taken from the
results themselves. The point is that a second model reading its own training data cannot catch a
stale fact; a live search can. Verdicts are cached per claim, so checking the same claim twice costs
nothing.

```
POST /api/v1/checks   { "text": "Rails 8 was released in March 2023." }
  →  contradicted · "The Rails blog dates the 8.0 release to November 2024."
     source: https://rubyonrails.org/2024/11/7/rails-8-no-paas-required
```

There is a browser demo at `GET /` and a JSON service description at `GET /api/v1`.

## Stack

Rails 8.1 (API-only) · Ruby 3.3 · MongoDB via Mongoid · HTTParty · Rack::Attack · RSpec + WebMock ·
198 specs, no live network calls

---

## Architecture

Three service objects, each with one job, composed by the third:

| Object | Input → output | Responsibility |
| ------ | -------------- | -------------- |
| `ClaimExtractorService` | text → `[Claim(claim:, type:)]` | Asks Claude for the independently checkable claims, each restated to stand alone, typed `fact` / `code_api` / `statistic`. Validates the JSON that comes back. |
| `ClaimVerifierService` | one claim → `{claim:, verdict:, reason:, source_url:}` | Claude writes a search query → SerpApi runs it → Claude rules on the claim against the snippets. Reformulates the query once if the results came back about something else. Validates the verdict. |
| `SerpGuardService` | text → the full report | Extracts once, then per claim prefers a cached verdict over the upstream calls a fresh one costs. Persists new verdicts. |

Below them sit two transports and nothing else:

```
app/services/
  serp_guard_service.rb            orchestrator
  claim_extractor_service.rb       text/code  → typed claims
  claim_verifier_service.rb        one claim  → verdict + reason + source
app/services/serp_guard/
  api_client.rb                    shared timeouts, retry policy, error mapping
  claude_client.rb                 Anthropic Messages API
  serpapi_client.rb                SerpApi Google Search
  errors.rb                        SerpGuard::Errors hierarchy
app/models/claim.rb                verdict cache, unique on claim_hash
app/serializers/                   the POST /checks wire format
app/controllers/concerns/          API key auth + the single error envelope
public/index.html                  browser demo: vanilla JS, no build step
```

### Why the transports are separate and injectable

HTTParty is called in exactly two files. Every service above them takes its client as a keyword
argument (`claude_client:`, `serpapi_client:`, `extractor:`, `verifier:`), defaulting to the real
one and built lazily so that input validation runs before anything touches a credential or a socket.

That buys three specific things:

- **Tests never bill a real API.** The whole suite stubs HTTP at one seam. `WebMock.disable_net_connect!`
  is on globally, so a new code path that tries to reach the network fails the suite instead of
  quietly spending money in CI.
- **The retry policy cannot drift.** Both clients inherit timeouts, the single retry, and the
  status → error mapping from `SerpGuard::ApiClient`. "Same conservative retry policy for every
  upstream call" is a requirement, and shared code is how you guarantee it rather than hope for it.
- **API-shape knowledge stays in one place.** That Claude interleaves thinking blocks with text
  blocks, that SerpApi reports "no results" as an `error` string on an HTTP 200 — each of those
  lives in its own client, not smeared across the services.

### Why a missed query gets one second chance

A query can read perfectly and still miss. A live run generated
`Ruby on Rails initial release year 2004` — which contains "Ruby on Rails" — and Google answered
with a civil rights activist's Instagram, a music video, a raid guide and Ruby-the-language. Drop
one word (`year`) and the same search returns "Hansson first released Rails as open source in July
2004" at position one.

Every component had behaved correctly: the claim was fine, the query was reasonable, and the verdict
step honestly reported that the snippets never mentioned Rails. The claim was simply unverifiable
from those results, so the answer was `unconfirmed` — right about the evidence, wrong about the world.

So the verifier checks whether the results mention any of the claim's distinctive terms — code
identifiers and *multi-word* proper nouns, never single capitalised words, because "Ruby" is exactly
what matched the activist and the raid guide. If a verdict comes back `unconfirmed` **and** the
results never mentioned the subject, the query is reformulated once and re-searched. It fires only on
that path, so the common case costs nothing extra.

The same run cited an Instagram reel for "the Eiffel Tower is in London". The verdict was right and
the citation was useless, so evidence is now ordered by source authority — reference works and
official docs ahead of social and video — before it reaches the model. Ordering only: nothing is
discarded, and a social post still carries a verdict when it is all Google returned.

### Why caching is per claim, not per request

The cache key is a SHA256 of the *normalized* claim text (case, whitespace and a trailing full stop
collapsed), unique-indexed in MongoDB — not a hash of the submitted document.

Caching whole requests would almost never hit: nobody pastes byte-identical text twice. Claims
repeat constantly. The same wrong fact about a Rails release date shows up in dozens of different
paragraphs, and the second paragraph that contains it should cost nothing. A cache hit returns the
stored verdict with `cached: true` and makes **zero** upstream calls.

Normalization is deliberately shallow — it collapses formatting noise, not meaning. Nothing more
aggressive (stemming, stop-word removal) is safe here, because a false cache hit is not a slow
answer, it is a **wrong** answer attributed to a source that never said it.

Two honest limits:

- **A repeat request is one Claude call, not zero.** Extraction runs every time; only verdicts are
  cached. Caching extraction per input text is the obvious next win.
- **There is no TTL, deliberately.** Search results go stale; the facts they establish mostly do
  not. Where that assumption breaks — time-sensitive claims, and cached `unconfirmed` verdicts,
  which often say more about what Google surfaced that minute than about the claim — is written out
  in `Claim.cached_verdict_for`, along with where to add freshness rules.

---

## Setup

### 1. Prerequisites

- Ruby 3.3 (`.ruby-version` pins the exact patch)
- A running MongoDB. Locally, either a native install or:
  ```sh
  docker run -d -p 27017:27017 --name serpguard-mongo mongo:7
  ```
- An [Anthropic API key](https://console.anthropic.com/settings/keys) and a
  [SerpApi key](https://serpapi.com/manage-api-key)

### 2. Install and configure

```sh
bundle install
cp .env.example .env     # then fill in the two upstream keys
```

Every variable is documented in [`.env.example`](.env.example). The required four:

| Variable | Purpose |
| -------- | ------- |
| `ANTHROPIC_API_KEY` | Extracts claims and rules on evidence |
| `SERPAPI_KEY` | Runs the Google search behind each claim |
| `SERPGUARD_API_KEYS` | Keys *your* clients send in `X-API-Key`, comma separated. Keep `demo-key` for the browser demo |
| `MONGODB_URI` | Verdict cache. Optional locally, required in production |

Create the unique index — declaring it in the model does not build it:

```sh
bin/rails db:mongoid:create_indexes
```

### 3. Run and test

```sh
bin/rails server                 # then open http://localhost:3000
bundle exec rspec                # 198 examples, needs a local mongod
bundle exec rubocop              # rubocop-rails-omakase
bundle exec rails zeitwerk:check # eager-load check, as production does it
```

The suite makes **no live HTTP calls**: `spec/rails_helper.rb` sets
`WebMock.disable_net_connect!(allow_localhost: false)`, and
[`spec/no_live_network_spec.rb`](spec/no_live_network_spec.rb) fails if that is ever loosened. It
passes with `ANTHROPIC_API_KEY`, `SERPAPI_KEY` and `SERPGUARD_API_KEYS` completely unset. MongoDB is
the one real dependency, and not by choice — the driver uses raw TCP sockets, which WebMock cannot
intercept, so the cache specs talk to a real `serpguard_test` database. A stubbed datastore would not
prove a unique index or a cache hit.

---

## API

| Method | Path | Auth | Notes |
| ------ | ---- | ---- | ----- |
| `GET` | `/` | no | Browser demo page |
| `GET` | `/api/v1` | no | Service description as JSON |
| `GET` | `/api/v1/health` | no | Liveness. Probes no dependency, so it never flaps |
| `POST` | `/api/v1/checks` | yes | Submit text or code, get a per-claim report |
| `GET` | `/up` | no | Rails' own boot check |

### Example

```sh
curl -X POST http://localhost:3000/api/v1/checks \
  -H 'content-type: application/json' \
  -H 'X-API-Key: demo-key' \
  -d '{"text":"Ruby 3.3 shipped YJIT as a production-ready JIT compiler. Rails 8 followed in March 2023.","max_claims":5}'
```

```json
{
  "checked_at": "2026-09-22T09:41:12Z",
  "input_summary": {
    "characters": 89,
    "claims_extracted": 2,
    "cached_claims": 0,
    "verdicts": { "verified": 1, "unconfirmed": 0, "contradicted": 1 }
  },
  "claims": [
    {
      "claim": "Ruby 3.3 shipped YJIT as a production-ready JIT compiler",
      "type": "fact",
      "verdict": "verified",
      "reason": "The Ruby 3.3.0 release announcement lists YJIT as production ready.",
      "source_url": "https://www.ruby-lang.org/en/news/2023/12/25/ruby-3-3-0-released/",
      "cached": false,
      "checked_at": "2026-09-22T09:41:12Z"
    },
    {
      "claim": "Rails 8 was released in March 2023",
      "type": "fact",
      "verdict": "contradicted",
      "reason": "The Rails blog dates the 8.0 release to November 2024.",
      "source_url": "https://rubyonrails.org/2024/11/7/rails-8-no-paas-required",
      "cached": false,
      "checked_at": "2026-09-22T09:41:12Z"
    }
  ]
}
```

Send the same text again and both claims come back `"cached": true` with no upstream calls at all.

`max_claims` is optional, clamped to 1–25 — an unseen claim costs two Claude calls and one SerpApi
search, or three and two when its first query has to be reformulated, so it is a spend limit as much
as a response-size one. A cached claim costs nothing.

### Verdicts

| Verdict | Means |
| ------- | ----- |
| `verified` | A result states or clearly implies the claim is correct |
| `contradicted` | A result states something incompatible with the claim |
| `unconfirmed` | The results neither support nor refute it — the claim is unsourced, not disproved |

**One deliberate exception, for `code_api` claims only.** If a claim names a method or API and
that name appears in **no** search result — across every query tried — the verdict is
`contradicted`, not `unconfirmed`, with `source_url: null`. A real method name returns *something*
for a search of its own name, so silence is evidence here in a way it is not for an ordinary fact.
The escalation is narrow on purpose: `code_api` claims only, only from `unconfirmed` (a ruling that
came from a snippet is never overridden), and never when the search returned nothing at all — zero
results means the query failed, not that the method is fake.

### Errors

Every failure uses one envelope: `{"error": {"code", "message", "request_id"}}`.

| Situation | Status | `code` |
| --------- | ------ | ------ |
| Missing or blank `text` | 400 | `parameter_missing` |
| Body is not valid JSON | 400 | `malformed_json` |
| Missing / unknown API key | 401 | `api_key_missing` · `api_key_invalid` |
| Bad `max_claims` | 422 | `validation_failed` |
| Text over 50,000 characters | 413 | `payload_too_large` |
| Over 30 checks/minute | 429 | `rate_limited` |
| No checkable claims found | 500 | `claim_extraction_failed` |
| Verdict could not be read | 500 | `verification_failed` |
| Upstream down after one retry | 500 | `verification_failed` |
| Our credentials rejected | 500 | `configuration_error` |

`rescue_from StandardError` is registered **first** in `ErrorHandling`, because
`ActiveSupport::Rescuable` matches handlers in *reverse* registration order — broadest first, most
specific last. Unknown exceptions re-raise when `Rails.env.local?`, so development and test keep real
backtraces instead of a tidy 500.

---

## Browser demo

`public/index.html` — one file, vanilla JS, no framework and no build step. A textarea, a **Check
Claims** button, and three preset chips that each exercise a different path:

| Chip | Input | Exercises |
| ---- | ----- | --------- |
| `mixed-facts` | One true claim and one subtly wrong date in a single paragraph | Two claims, opposite verdicts, one input |
| `code-hallucination` | A snippet using real `String#squish` and invented `Enumerable#sum_by` | `code_api` claims; the invented one comes back `contradicted`, not merely unsourced |
| `outdated-stat` | A version and a gem count that were both true once | A `statistic` that live results should now contradict |

Results render one card per claim with a verdict badge (green / yellow / red), the reason and a
clickable source. A status strip shows HTTP status, response time, claims checked, how many came from
cache, and the verdict tally; raw JSON sits in a collapsed `<details>`. After 2.5s with no response, a
cold-start notice explains that the free instance is waking up.

It prefills a preset but **does not auto-submit** — unlike a read-only search console, every run
spends Claude and SerpApi credits, so the visitor decides when. The chip labels describe their
*input*, never a promised verdict: the verdict comes from whatever Google returns at that moment.

---

## Engineering notes

### 1. Verdicts are graded against live snippets, never the model's own knowledge

The obvious way to build this is to ask Claude "is this claim true?" It would be shorter, cheaper,
and one API call instead of three. It would also be worthless for the failure mode that actually
matters.

A model's knowledge is frozen at its training cutoff, and the claims most likely to be wrong in
AI-generated text are exactly the ones a model is most likely to be confidently wrong about: current
versions, recent releases, "the latest X", a statistic that moved. Asking a model to check another
model's output is two draws from overlapping distributions — when both are wrong, they agree, and the
check returns `verified` with total confidence. That is worse than no check at all, because it
launders a hallucination as a verified fact.

So the verdict prompt is explicitly told to rule against the provided snippets and *not* from its own
knowledge, however confident it is. Claude is used for the two things it is genuinely good at —
deciding what counts as a checkable claim, and judging whether a snippet supports a sentence — while
the *evidence* comes from a live Google search. The search is the source of truth; the model is the
reader.

That choice has teeth elsewhere in the code. A `source_url` is kept only if it matches a result we
actually handed over; a URL the model invented is dropped and logged rather than passed on as a
citation. And when Google returns nothing, the service short-circuits to `unconfirmed` without asking
for a verdict at all — because a verdict with no evidence behind it is exactly the thing this design
exists to avoid.

### 2. A parse failure must never become `unconfirmed`

`unconfirmed` is a finding. It means: we searched, we read the results, and they neither support nor
refute the claim. A user can act on that — it says the claim is unsourced.

An unreadable verdict means something completely different: we do not know. Claude returned
malformed JSON, or a verdict string outside the three allowed values, or a reply truncated at the
token limit. The temptation is to fall back to `unconfirmed`, because it is the "safe" middle value
and the request then always succeeds.

That fallback would be a silent data-corruption bug. Every such failure would be indistinguishable
from a real finding, the endpoint would keep returning 200, and the only symptom would be a slow
drift toward `unconfirmed` that nobody notices — in a product whose entire value is that its output
can be trusted. Worse, it hides the bug: a prompt regression that breaks JSON output 30% of the time
would look like "lots of unsourced claims" rather than an outage.

So `ClaimVerifierService` raises `VerificationFailed` on every unreadable answer and there is no code
path from a parse error to a verdict. The endpoint returns 500 and says why.
[A spec exists purely to pin that behaviour](spec/services/claim_verifier_service_spec.rb), because
it is the kind of invariant a future "let's make this more resilient" refactor would quietly remove.

The same principle runs through the error hierarchy: a blank claim is a 422, a missing credential is a
500 `configuration_error`, an upstream outage is distinct from a parse failure. Collapsing them into
one generic "something went wrong" would be easier to write and impossible to debug.

### 3. Absence of evidence — for code APIs, and nowhere else

Note 1 says the model rules on what the sources say, not on what it knows. Note 2 says a verdict we
could not read is never quietly downgraded. This is the one place the rules bend, and it is worth
being explicit about why.

`unconfirmed` for `ActiveRecord::Base.magic_query` is defensible — no snippet says a method *does
not* exist — and it is also close to useless. Catching hallucinated code references is the reason
this project exists, and answering "we could not find out" about an invented method buries the single
most valuable thing the system found.

The asymmetry that justifies it: a real method name returns *something* for a search of its own name
— docs, a changelog, a Stack Overflow question, an angry blog post. An ordinary fact has no such
guarantee; plenty of true statements are simply not written down anywhere Google indexes. So silence
carries information for a code identifier that it does not carry for a fact, and the escalation is
restricted to exactly that case.

It is still an inference rather than a citation, so it is fenced in: `code_api` claims only, only
from `unconfirmed`, only after every query has been tried, never when the search returned nothing,
and always with `source_url: null` — there is no result to cite for an absence, and inventing one
would be the very thing the URL check exists to prevent.

### 4. What I'd do differently at real scale

- **Fan out the per-claim verification.** It is sequential today; ten claims are ten round trips.
  A job queue with per-claim jobs and a polled result would cut wall-clock time substantially.
- **Cache extraction, not just verdicts.** Re-submitting the same document still pays for extraction.
- **Revisit the no-TTL decision for `unconfirmed`.** Those are the verdicts most likely to change on
  a re-check, and the ones least useful to keep forever.

---

## Deployment

Not deployed yet. [`render.yaml`](render.yaml) is a Render blueprint with the settings already
filled in:

| Setting | Value |
| ------- | ----- |
| Runtime | Ruby |
| Build Command | `bundle install` |
| Start Command | `bundle exec puma -C config/puma.rb` |
| Health Check Path | `/api/v1/health` |

Three things that will bite otherwise:

1. **Render's dashboard pre-fills a build command containing `rake assets:precompile`.** This is an
   API-only app with no asset pipeline, so that task does not exist and the build aborts. `render.yaml`
   sets the build command explicitly, which avoids it; if you configure by hand, delete it.
2. **`Gemfile.lock` needs the Linux platform.** Bundler refuses to install on a Linux build host
   otherwise. Already done here — re-run after changing gems:
   ```sh
   bundle lock --add-platform x86_64-linux
   ```
3. **Create the index once, from your machine.** `preDeployCommand` is not available on Render's free
   plan, so point the task at the production database yourself:
   ```sh
   MONGODB_URI="<atlas-uri>" RAILS_ENV=production bin/rails db:mongoid:create_indexes
   ```
   Without it, uniqueness still holds (the model validates it) but a concurrent double-write is
   possible and lookups are unindexed.

**MongoDB Atlas:** an M0 cluster is enough. Allow `0.0.0.0/0` in Network Access — free-tier hosts
have no static outbound IP — and put the database name in the URI path.

Environment variables to set: `MONGODB_URI`, `ANTHROPIC_API_KEY`, `SERPAPI_KEY`,
`SERPGUARD_API_KEYS` (include `demo-key` if you want the public demo page to work). `RAILS_ENV` and
`WEB_CONCURRENCY=1` are already in the blueprint.

### Production notes

- **`WEB_CONCURRENCY=1` on a free instance.** Each Puma worker loads the whole app into 512MB.
  Rack::Attack's counters live in `Rails.cache`, a `FileStore` here, so rate limits are per-instance
  regardless of worker count — scaling horizontally means each instance gets its own budget.
- **The free instance sleeps after 15 minutes.** The first request can take up to a minute; the demo
  page says so after 2.5 seconds rather than looking broken.
- **`GET /` works with or without static file serving.** `ActionDispatch::Static` serves
  `public/index.html` before the router when it is enabled; `MetaController#show` serves the same
  bytes when it is not.
