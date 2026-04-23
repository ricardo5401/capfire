require 'json'

# Thin wrapper around a Rails streaming response that formats Server-Sent Events.
#
# Usage:
#   sse = SseWriter.new(response.stream)
#   sse.event(:log, line: "...")
#   sse.event(:done, exit_code: 0)
#   sse.close
class SseWriter
  HEARTBEAT_COMMENT = ": keep-alive\n\n".freeze

  def initialize(stream)
    @stream = stream
    @closed = false
  end

  # Sends a named SSE event with a JSON-encoded data payload.
  def event(name, data = {})
    return if @closed

    payload = "event: #{name}\n" \
              "data: #{JSON.generate(data)}\n\n"
    write(payload)
  end

  # Sends a raw comment line — useful as a heartbeat to keep proxies from closing the connection.
  def heartbeat
    write(HEARTBEAT_COMMENT)
  end

  def close
    return if @closed

    @closed = true
    @stream.close
  rescue IOError, Errno::EPIPE
    # Client disconnected — nothing to do.
  end

  def closed?
    @closed
  end

  private

  def write(data)
    @stream.write(data)
  rescue IOError, Errno::EPIPE
    @closed = true
  end
end
