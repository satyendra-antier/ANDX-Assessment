CREATE TABLE IF NOT EXISTS andx_blocks (
  number bigint NOT NULL,
  hash text PRIMARY KEY,
  parent_hash text NOT NULL
);

CREATE TABLE IF NOT EXISTS andx_indexer_head (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  head_block bigint NOT NULL DEFAULT 0,
  head_hash text NOT NULL DEFAULT '',
  finalized_block bigint NOT NULL DEFAULT 0,
  finalized_hash text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO andx_indexer_head (id, head_block, head_hash, finalized_block, finalized_hash)
VALUES (1, 0, '', 0, '')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS andx_events (
  block_number bigint NOT NULL,
  block_hash text NOT NULL,
  log_index int NOT NULL,
  tx_hash text NOT NULL,
  event_name text NOT NULL,
  campaign_id text,
  args jsonb NOT NULL,
  finalized boolean NOT NULL DEFAULT false,
  PRIMARY KEY (block_hash, log_index)
);

CREATE INDEX IF NOT EXISTS andx_events_block_number_idx ON andx_events (block_number);
CREATE INDEX IF NOT EXISTS andx_events_campaign_id_idx ON andx_events (campaign_id);

CREATE TABLE IF NOT EXISTS andx_campaign_state (
  campaign_id text PRIMARY KEY,
  net_deposited numeric NOT NULL DEFAULT 0,
  active_committed numeric NOT NULL DEFAULT 0,
  pending_committed numeric NOT NULL DEFAULT 0,
  claimed_total numeric NOT NULL DEFAULT 0,
  refunded numeric NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS andx_relay_jobs (
  id bigserial PRIMARY KEY,
  campaign_id text NOT NULL,
  creator text NOT NULL,
  cumulative_amount numeric NOT NULL,
  recipient text NOT NULL,
  relayer_fee numeric NOT NULL DEFAULT 0,
  nonce numeric NOT NULL,
  deadline numeric NOT NULL,
  signature text NOT NULL,
  proof jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  tx_hash text,
  raw_tx text,
  gas_price numeric,
  nonce_used bigint,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS andx_relay_jobs_status_idx ON andx_relay_jobs (status);

CREATE TABLE IF NOT EXISTS andx_relayer_nonce (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  next_nonce bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO andx_relayer_nonce (id, next_nonce) VALUES (1, 0)
ON CONFLICT (id) DO NOTHING;
