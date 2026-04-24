# frozen_string_literal: true

# At boot, mark any deploy left in `pending` or `running` state as `failed`.
#
# Context: Capfire runs deploys either inline (SSE) or in a background Thread
# (async mode). Both live in the SAME process — there's a single Puma worker.
# If the process crashes, is killed, or the machine reboots, whatever deploys
# were in-flight lose their Thread AND their ability to finalize. The Deploy
# records, however, stay with `status = running` in the DB forever, which
# holds the unique partial index (see idx_deploys_active_per_app) and
# permanently blocks new deploys with HTTP 409 — silent deadlock.
#
# Because of the single-worker invariant, ANY running/pending deploy at boot
# time is definitively orphan (no other Capfire process could own it). Marking
# them failed releases the lock, lets Slack notifications NOT fire (the
# original run already failed without posting), and leaves a clear audit
# trail: the row shows `status = failed`, `exit_code = 1`, finished_at set.
#
# Skipped when:
#   - The DB schema isn't loaded yet (first migration, initial setup, etc.)
#   - Rails is running a rake task that doesn't need the DB (db:create, etc.)
#
# SAFETY: do not change Capfire to use multiple workers without rethinking
# this — with parallel workers, an "active" deploy from the other worker is
# NOT orphan, and this initializer would sabotage it. Single-worker guarantee
# lives in config/puma.rb (`workers 1`).

Rails.application.config.after_initialize do
  next unless defined?(Deploy)
  next unless Deploy.table_exists?

  orphans = Deploy.active
  next if orphans.none?

  count = orphans.count
  now = Time.current

  # Append an audit note to the log so the row tells its own story.
  note = "\n[orphan] Capfire process restarted — deploy marked as failed at #{now.iso8601}.\n"
  quoted_note = ActiveRecord::Base.connection.quote(note)

  # Use update_all so this runs as a single UPDATE without callbacks/validations.
  orphans.update_all(
    status: 'failed',
    exit_code: 1,
    finished_at: now,
    updated_at: now,
    log: Arel.sql("COALESCE(log, '') || #{quoted_note}")
  )

  Rails.logger.warn("[orphan-deploys] Reclaimed #{count} orphan deploy record(s) at boot")
rescue ActiveRecord::ActiveRecordError => e
  # Happens early in provisioning (db not ready yet). Don't crash the boot.
  Rails.logger.warn("[orphan-deploys] Skipped: #{e.class}: #{e.message}")
end
