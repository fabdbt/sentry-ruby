module Sentry
  class SessionFlusher
    include LoggingHelper

    FLUSH_INTERVAL = 60

    def initialize(configuration, client)
      @thread = nil
      @client = client
      @pending_aggregates = {}
      @release = configuration.release
      @environment = configuration.environment
      @logger = configuration.logger

      log_debug("[Sessions] Sessions won't be captured without a valid release") unless @release
    end

    def flush
      return if @pending_aggregates.empty?

      Sentry.background_worker.perform do
        @client.transport.send_envelope(envelope)
      end

      @pending_aggregates = {}
    end

    def add_session(session)
      return unless @release

      ensure_thread

      return unless Session::AGGREGATE_STATUSES.include?(session.status)
      @pending_aggregates[session.started_bucket] ||= init_aggregates
      @pending_aggregates[session.started_bucket][session.status] += 1
    end

    def kill
      @thread&.kill
    end

    private

    def init_aggregates
      Session::AGGREGATE_STATUSES.map { |k| [k, 0] }.to_h
    end

    def envelope
      envelope = Envelope.new

      header = { type: 'sessions' }
      payload = { attrs: attrs, aggregates: aggregates_payload }

      envelope.add_item(header, payload)
      envelope
    end

    def attrs
      { release: @release, environment: @environment }
    end

    def aggregates_payload
      @pending_aggregates.map do |started, aggregates|
        aggregates[:started] = started.iso8601
        aggregates
      end
    end

    def ensure_thread
      return if @thread&.alive?

      @thread = Thread.new do
        loop do
          sleep(FLUSH_INTERVAL)
          flush
        end
      end
    end

  end
end
