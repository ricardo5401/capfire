require 'json'

# Thin wrapper around a Rails streaming response that formats Server-Sent Events.
#
# Usage:
#   sse = SseWriter.new(response.stream)
#   sse.event(:log, line: "...")
#   sse.event(:done, exit_code: 0)
#   sse.close
#
# Automatically emits an SSE comment line every `HEARTBEAT_INTERVAL` seconds so
# silent gaps in the deploy (vite build, long DB migrations, slow asset rsync)
# don't trip idle-connection timeouts at nginx / Cloudflare / corporate
# proxies. The heartbeat thread dies cleanly when `close` is called.
class SseWriter
  HEARTBEAT_COMMENT = ": keep-alive\n\n".freeze
  HEARTBEAT_INTERVAL = 15 # seconds

  def initialize(stream)
    @stream = stream
    @closed = false
    @mutex = Mutex.new
    start_heartbeat
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
    stop_heartbeat
    @stream.close
  rescue IOError, Errno::EPIPE
    # Client disconnected — nothing to do.
  end

  def closed?
    @closed
  end

  private

  def write(data)
    @mutex.synchronize do
      return if @closed

      @stream.write(data)
    end
  rescue IOError, Errno::EPIPE
    @closed = true
  end

  def start_heartbeat
    @heartbeat_thread = Thread.new do
      loop do
        sleep HEARTBEAT_INTERVAL
        break if @closed

        heartbeat
      end
    rescue StandardError
      # Silently stop — the client disconnected or the stream broke.
    end
  end

  def stop_heartbeat
    @heartbeat_thread&.kill
    @heartbeat_thread = nil
  end
end
