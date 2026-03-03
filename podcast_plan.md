## VC Podcast Intelligence Pipeline (Ruby-first, low-cost, cloud-ready)

### Summary
Build a Ruby service inside your existing `vc-signal-tools` project that ingests 3 RSS podcasts daily, transcribes new episodes, generates VC-relevant analysis summaries, stores outputs in a Postgres-compatible schema (starting local SQLite), and sends a structured Markdown digest email at **7:00 AM local time** every day.  
Design target is **<$50/month** AI spend using strict chunking, selective prompting, caching, and small-model defaults.

### Scope
1. In scope:
- RSS ingestion for a curated podcast set
- Episode metadata storage
- Transcript storage and chunking
- Multi-stage analysis (summary + investment signal extraction)
- Daily Markdown email digest
- Local SQLite now, cloud Postgres migration-ready schema
2. Out of scope (v1):
- YouTube ingestion
- Full semantic search UI
- Real-time streaming/transcription
- Crypto/biotech-specific thematic tracking

### Recommended v1 podcast set (3 feeds)
1. The Twenty Minute VC (VC perspectives + founder/operator insights)
2. Latent Space: The AI Engineer Podcast (emerging AI/infra/dev tools signal)
3. The Full Ratchet (early-stage investing and founder interviews)

### Broader podcast pool for later expansion
1. a16z Podcast  
2. Invest Like the Best  
3. Acquired  
4. No Priors  
5. StrictlyVC Download  
6. The Logan Bartlett Show  
7. The Peel (or equivalent early-stage founder interview show)  
8. All-In (use selectively; macro noise filter needed)  
9. This Week in Startups (selective episode filter)  
10. Lenny’s Podcast (product + founder/operator overlap)

### Architecture and components
1. `PodcastIngestor`:
- Pull RSS feeds
- Normalize episode metadata
- Detect new/unprocessed episodes
2. `TranscriptService`:
- Download episode audio from enclosure URL
- Run transcription with a low-cost speech model
- Store raw transcript + confidence/quality metadata
3. `AnalysisService`:
- Chunk transcript
- Run map-reduce summarization
- Extract structured VC signals (sector, stage cues, GTM insight, notable founder quotes, market risks)
4. `DigestBuilder`:
- Build one Markdown digest for all episodes processed in last 24h
- Rank insights by relevance to Crosslink focus sectors
5. `EmailNotifier`:
- Reuse existing SMTP flow
- Send digest at 7:00 AM local daily
6. `Scheduler`:
- Use cron or `rufus-scheduler`
- Separate ingest cadence (hourly) and digest send cadence (daily)

### Data model (Postgres-compatible from day 1)
1. `podcasts`:
- `id`, `name`, `rss_url`, `category_tags`, `active`, `created_at`, `updated_at`
2. `episodes`:
- `id`, `podcast_id`, `guid` (unique), `title`, `published_at`, `audio_url`, `duration_sec`, `status`, `created_at`, `updated_at`
3. `transcripts`:
- `id`, `episode_id`, `provider`, `model`, `language`, `raw_text`, `token_estimate`, `created_at`
4. `transcript_chunks`:
- `id`, `transcript_id`, `chunk_index`, `text`, `token_estimate`
5. `episode_analyses`:
- `id`, `episode_id`, `summary_md`, `key_takeaways_json`, `investment_signals_json`, `risks_json`, `action_items_json`, `model`, `created_at`
6. `daily_digests`:
- `id`, `digest_date`, `content_md`, `episode_count`, `sent_at`, `delivery_status`
7. `processing_jobs`:
- `id`, `job_type`, `entity_type`, `entity_id`, `status`, `error_message`, `attempts`, `started_at`, `finished_at`

### Public interfaces and commands
1. `bin/podcast_ingest`:
- Fetch feeds, upsert podcasts/episodes, enqueue work
2. `bin/podcast_transcribe`:
- Process queued episodes without transcripts
3. `bin/podcast_analyze`:
- Process transcripts into structured analyses
4. `bin/send_daily_digest`:
- Build and send Markdown digest email
5. `bin/run_podcast_pipeline`:
- Orchestrate full flow (for cron/scheduler use)
6. Config files:
- `config/podcast_feeds.yml`
- `config/pipeline.yml` (budget caps, chunk sizes, model selections)

### Model strategy (best-per-task mix, cost constrained)
1. Transcription:
- Use lowest-cost reliable speech model first
- Fallback to higher-accuracy speech model only for low-confidence transcripts
2. Summarization and extraction:
- Use small chat model for chunk summaries
- Use small/medium model once per episode for final synthesis and structured JSON signal extraction
3. Cost controls:
- Max transcript tokens per episode cap
- Skip/trim low-relevance segments (ads, intros, outros)
- Cache prompt outputs keyed by transcript hash
- Hard monthly budget guardrail with automatic downgrade mode

### Daily digest format
1. Email subject:
- `VC Podcast Digest — YYYY-MM-DD`
2. Markdown body sections:
- Top 5 investment signals
- Episode-by-episode summaries (5-8 bullets each)
- Founder tactics and GTM ideas
- Market/technical risks observed
- “Why it matters for Crosslink” tags (`AI`, `DevTools`, `Infra`, `Marketplace`, `Consumer`, `Vertical SaaS`, `Health Tech`)
- Follow-up reading/listening queue

### Testing and validation
1. Unit tests:
- RSS parsing and dedup by GUID
- Chunking logic and token budget enforcement
- JSON extraction schema validation
- Digest rendering correctness
2. Integration tests:
- End-to-end pipeline on 1 short sample episode
- SMTP send path (mocked)
- Retry behavior for failed transcription/analysis jobs
3. Acceptance criteria:
- New episodes are detected automatically from all 3 feeds
- Each episode gets transcript + structured analysis rows
- One digest email is delivered at 7:00 AM local with valid Markdown content
- Total projected monthly API usage remains under configured cap in normal volume

### Rollout plan
1. Phase 1:
- Implement schema + ingestion + one-feed dry run
2. Phase 2:
- Add transcription + analysis + digest generation locally
3. Phase 3:
- Enable daily scheduler and SMTP delivery
4. Phase 4:
- Migrate DB backend to managed Postgres (no schema redesign required)

### Assumptions and defaults
1. Language is Ruby for v1, using your existing `vc-signal-tools` structure.
2. Source scope is RSS-only in v1.
3. Cloud path is Postgres-compatible schema; local dev starts on SQLite.
4. Delivery is Markdown in email body, daily at 7:00 AM local.
5. Monthly spend target is under $50 with automatic guardrails.
6. Crypto and biotech signals are excluded from ranking/tag emphasis.
