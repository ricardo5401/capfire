# frozen_string_literal: true

require 'faraday'
require 'json'

# Posts deploy lifecycle notifications to a Slack Incoming Webhook.
#
# Fire-and-forget by design: Slack failures are logged but never raise, so a
# hiccup on Slack's side can't abort an otherwise successful deploy or mask
# the real error of a failed one.
#
# Message format uses Slack's `attachments` + `blocks` (Block Kit) to get:
#   - a colored bar on the left (green for success, red for failure),
#   - a header with emoji,
#   - a 2-column grid with app/env/branch/author,
#   - an "Abrir" primary button when a `link` is provided.
#
# Webhook URL is read from `ENV['SLACK_WEBHOOK_URL']` by default — a single
# channel for all apps on this Capfire node. If per-app routing is needed,
# `capfire.yml` can override the env var name via `slack.webhook_env`.
class SlackNotifier
  DEFAULT_WEBHOOK_ENV = 'SLACK_WEBHOOK_URL'

  SUCCESS_COLOR = '#36a64f'
  FAILURE_COLOR = '#d23c3c'

  def initialize(webhook_url: nil, webhook_env: DEFAULT_WEBHOOK_ENV, logger: Rails.logger)
    @webhook_url = webhook_url.presence || ENV[webhook_env].presence
    @logger = logger
  end

  def configured?
    @webhook_url.present?
  end

  def notify_success(app:, env:, branch:, author:, link: nil)
    payload = build_payload(
      color: SUCCESS_COLOR,
      header: ':rocket:  Deploy exitoso',
      fallback: "Deploy exitoso: #{app} (#{env}) #{branch} by #{display_author(author)}",
      app: app, env: env, branch: branch, author: author, link: link
    )
    post(payload)
  end

  def notify_failure(app:, env:, branch:, author:, reason:, link: nil)
    payload = build_payload(
      color: FAILURE_COLOR,
      header: ':x:  Deploy fallido',
      fallback: "Deploy fallido: #{app} (#{env}) #{branch} by #{display_author(author)} — #{reason}",
      app: app, env: env, branch: branch, author: author, link: link,
      reason: reason
    )
    post(payload)
  end

  private

  def build_payload(color:, header:, fallback:, app:, env:, branch:, author:, link:, reason: nil)
    blocks = [
      header_block(header),
      fields_block(app: app, env: env, branch: branch, author: author)
    ]
    blocks << reason_block(reason) if reason.present?
    blocks << actions_block(link) if link.present?

    {
      attachments: [
        {
          color: color,
          fallback: fallback,
          blocks: blocks
        }
      ]
    }
  end

  def header_block(text)
    { type: 'header', text: { type: 'plain_text', text: text, emoji: true } }
  end

  def fields_block(app:, env:, branch:, author:)
    {
      type: 'section',
      fields: [
        { type: 'mrkdwn', text: "*App*\n#{app}" },
        { type: 'mrkdwn', text: "*Ambiente*\n`#{env}`" },
        { type: 'mrkdwn', text: "*Rama*\n`#{branch}`" },
        { type: 'mrkdwn', text: "*Por*\n#{display_author(author)}" }
      ]
    }
  end

  def reason_block(reason)
    {
      type: 'section',
      text: { type: 'mrkdwn', text: "*Motivo*\n```#{truncate(reason, 800)}```" }
    }
  end

  def actions_block(link)
    {
      type: 'actions',
      elements: [
        {
          type: 'button',
          text: { type: 'plain_text', text: 'Abrir app', emoji: true },
          url: link,
          style: 'primary'
        }
      ]
    }
  end

  def display_author(author)
    author.presence || 'unknown'
  end

  def truncate(text, limit)
    return '' if text.blank?
    return text if text.length <= limit

    "#{text[0, limit]}..."
  end

  def post(payload)
    return unless configured?

    response = Faraday.post(@webhook_url, JSON.generate(payload), 'Content-Type' => 'application/json')

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
