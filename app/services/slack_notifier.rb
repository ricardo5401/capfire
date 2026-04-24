# frozen_string_literal: true

require 'faraday'
require 'json'

# Posts deploy lifecycle notifications to a Slack Incoming Webhook.
#
# Fire-and-forget by design: Slack failures are logged but never raise, so a
# hiccup on Slack's side can't abort an otherwise successful deploy or mask
# the real error of a failed one.
#
# Webhook URL is read from `ENV['SLACK_WEBHOOK_URL']` by default — a single
# channel for all apps on this Capfire node. If per-app routing is needed,
# `capfire.yml` can override the env var name via `slack.webhook_env`.
class SlackNotifier
  DEFAULT_WEBHOOK_ENV = 'SLACK_WEBHOOK_URL'

  def initialize(webhook_url: nil, webhook_env: DEFAULT_WEBHOOK_ENV, logger: Rails.logger)
    @webhook_url = webhook_url.presence || ENV[webhook_env].presence
    @logger = logger
  end

  def configured?
    @webhook_url.present?
  end

  def notify_success(app:, env:, branch:, author:, link: nil)
    post(build_success_text(app: app, env: env, branch: branch, author: author, link: link))
  end

  def notify_failure(app:, env:, branch:, author:, reason:, link: nil)
    post(build_failure_text(app: app, env: env, branch: branch, author: author, reason: reason, link: link))
  end

  private

  def build_success_text(app:, env:, branch:, author:, link:)
    parts = [
      ":rocket: Se desplegaron nuevos cambios en *#{app}* (`#{env}`)",
      "Rama: `#{branch}` — by *#{display_author(author)}*"
    ]
    parts << "<#{link}|Abrir>" if link.present?
    parts.join(' — ')
  end

  def build_failure_text(app:, env:, branch:, author:, reason:, link:)
    parts = [
      ":x: Fallo el deploy de *#{app}* (`#{env}`)",
      "Rama: `#{branch}` — by *#{display_author(author)}*",
      "Motivo: #{truncate(reason, 200)}"
    ]
    parts << "<#{link}|Abrir>" if link.present?
    parts.join(' — ')
  end

  def display_author(author)
    author.presence || 'unknown'
  end

  def truncate(text, limit)
    return '' if text.blank?
    return text if text.length <= limit

    "#{text[0, limit]}..."
  end

  def post(text)
    return unless configured?

    response = Faraday.post(@webhook_url, JSON.generate(text: text), 'Content-Type' => 'application/json')

    if response.success?
      @logger.info("[slack] posted OK (HTTP #{response.status})")
    else
      @logger.error("[slack] webhook returned HTTP #{response.status}: #{response.body.to_s[0, 200]}")
    end

    response
  rescue StandardError => e
    @logger.error("[slack] notification failed: #{e.class}: #{e.message}")
  end
end
