# frozen_string_literal: true

module Catpm
  class StackSampler
    MS_PER_SECOND = 1000.0
    MIN_SEGMENT_DURATION_MS = 1.0
    CALL_TREE_SAMPLE_INTERVAL = 0.001 # 1ms — higher resolution for call tree reconstruction
    SAMPLING_THREAD_PRIORITY = -1

    # Single global thread that samples all active requests.
    # Avoids creating a thread per request.
    class SamplingLoop
      def initialize
        @mutex = Mutex.new
        @samplers = []
        @thread = nil
        @stop = false
      end

      def register(sampler)
        @mutex.synchronize do
          @samplers << sampler
          @stop = false
          start_thread unless @thread&.alive?
        end
      end

      def unregister(sampler)
        @mutex.synchronize do
          @samplers.delete(sampler)
          @stop = true if @samplers.empty?
        end
      end

      private

      def start_thread
        @stop = false
        @thread = Thread.new do
          loop do
            break if @stop

            interval = if Catpm.config.instrument_call_tree
              [CALL_TREE_SAMPLE_INTERVAL, Catpm.config.stack_sample_interval].min
            else
              Catpm.config.stack_sample_interval
            end
            sleep(interval)
            sample_all
          end
        end
        @thread.priority = SAMPLING_THREAD_PRIORITY
      end

      def sample_all
        targets = @mutex.synchronize { @samplers.dup }
        return if targets.empty?

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        targets.each { |s| s.capture(now) }
      end
    end

    @loop = SamplingLoop.new

    class << self
      attr_reader :loop
    end

    def initialize(target_thread:, request_start:, call_tree: false)
      @target = target_thread
      @request_start = request_start
      @samples = []
      @call_tree = call_tree
    end

    def start
      self.class.loop.register(self)
    end

    def stop
      self.class.loop.unregister(self)
    end

    # Called by SamplingLoop from the global thread
    def capture(now)
      max = Catpm.config.max_stack_samples_per_request
      return if max && @samples.size >= max

      locs = @target.backtrace_locations
      @samples << [now, locs] if locs
    end

    # Returns array of { parent: {segment}, children: [{segment}, ...] }
    # Parent = app code frame that initiated the work
    # Children = gem internals (collapsed by default in UI)
    def to_segments(tracked_ranges: [])
      return [] if @samples.size < 2

      untracked = @samples.reject do |time, _|
        tracked_ranges.any? { |s, e| time >= s && time <= e }
      end
      return [] if untracked.empty?

      # Annotate: [time, app_frame (caller), leaf_frame (execution point)]
      annotated = untracked.filter_map do |time, locs|
        pair = extract_frame_pair(locs)
        next unless pair
        [time, pair[0], pair[1]]
      end
      return [] if annotated.empty?

      # Group consecutive samples by app_frame
      groups = []
      current = nil

      annotated.each do |time, app_frame, leaf_frame|
        app_key = app_frame ? frame_key(app_frame) : nil

        if current && current[:app_key] == app_key
          current[:end_time] = time
          current[:count] += 1
          current[:leaves] << [time, leaf_frame]
        else
          groups << current if current
          current = {
            app_key: app_key,
            app_frame: app_frame,
            start_time: time,
            end_time: time,
            count: 1,
            leaves: [[time, leaf_frame]]
          }
        end
      end
      groups << current if current

      groups.filter_map do |group|
        duration = estimate_duration(group)
        next if duration < MIN_SEGMENT_DURATION_MS

        offset = ((group[:start_time] - @request_start) * MS_PER_SECOND).round(2)
        app_frame = group[:app_frame]
        leaf = group[:leaves].first&.last

        # Build parent segment — always the app frame if available
        if app_frame
          app_path = app_frame.path.to_s
          parent = {
            type: 'code',
            detail: build_app_detail(app_frame),
            duration: duration.round(2),
            offset: offset,
            source: "#{app_path}:#{app_frame.lineno}",
            started_at: group[:start_time]
          }

          # Children = gem internals (only if leaf differs from app frame)
          children = build_children(group[:leaves])
          # Skip children that are identical to parent (pure app code)
          children.reject! { |c| c[:detail] == parent[:detail] }

          { parent: parent, children: children }
        elsif leaf
          # No app frame — show leaf directly, no children
          path = leaf.path.to_s
          parent = {
            type: classify_path(path),
            detail: build_gem_detail(leaf),
            duration: duration.round(2),
            offset: offset,
            started_at: group[:start_time]
          }
          { parent: parent, children: [] }
        end
      end
    end

    # Build a call tree from samples — replacement for TracePoint-based CallTracer.
    # Returns flat array of segments with :_tree_parent (relative index or nil for top-level).
    def to_call_tree(tracked_ranges: [])
      return [] if @samples.size < 2

      # Build a tree of app-frame call chains across all samples
      tree = {} # key → {frame:, children: {}, count:, first_time:, last_time:}

      @samples.each do |time, locs|
        chain = extract_app_chain(locs)
        next if chain.empty?

        current_level = tree
        chain.each do |frame|
          key = frame_key(frame)
          unless current_level.key?(key)
            current_level[key] = {
              frame: frame, children: {}, count: 0,
              first_time: time, last_time: time
            }
          end
          node = current_level[key]
          node[:count] += 1
          node[:last_time] = time
          current_level = node[:children]
        end
      end

      # Flatten tree into segments with relative parent references
      segments = []
      flatten_call_tree(tree, segments, nil)
      segments
    end

    private

    # Extract all app frames from a backtrace, ordered caller-first (outer → inner).
    def extract_app_chain(locations)
      frames = []
      locations.each do |loc|
        path = loc.path.to_s
        next if path.start_with?('<internal:')
        next if path.include?('/catpm/')
        next if path.include?('/ruby/') && !path.include?('/gems/')

        frames << loc if Fingerprint.app_frame?(path)
      end
      frames.reverse
    end

    def flatten_call_tree(children_hash, segments, parent_idx)
      children_hash.each_value do |node|
        duration = call_tree_node_duration(node)
        next if duration < MIN_SEGMENT_DURATION_MS

        frame = node[:frame]
        seg = {
          type: 'code',
          detail: build_app_detail(frame),
          duration: duration.round(2),
          offset: ((node[:first_time] - @request_start) * MS_PER_SECOND).round(2),
          source: "#{frame.path}:#{frame.lineno}",
          _tree_parent: parent_idx
        }

        idx = segments.size
        segments << seg

        flatten_call_tree(node[:children], segments, idx)
      end
    end

    def call_tree_node_duration(node)
      interval = Catpm.config.instrument_call_tree ?
        [CALL_TREE_SAMPLE_INTERVAL, Catpm.config.stack_sample_interval].min :
        Catpm.config.stack_sample_interval
      [
        (node[:last_time] - node[:first_time]) * MS_PER_SECOND,
        node[:count] * interval * MS_PER_SECOND
      ].max
    end

    # Walk the stack: find the leaf (deepest interesting frame)
    # and the app_frame (nearest app code above the leaf)
    def extract_frame_pair(locations)
      leaf_frame = nil
      app_frame = nil

      locations.each do |loc|
        path = loc.path.to_s
        next if path.start_with?('<internal:')
        next if path.include?('/catpm/')
        next if path.include?('/ruby/') && !path.include?('/gems/')

        leaf_frame ||= loc

        if Fingerprint.app_frame?(path)
          app_frame = loc
          break
        end
      end

      return nil unless leaf_frame
      [app_frame, leaf_frame]
    end

    def build_children(leaves)
      spans = []
      current = nil

      leaves.each do |time, frame|
        key = frame_key(frame)

        if current && current[:key] == key
          current[:end_time] = time
          current[:count] += 1
        else
          spans << current if current
          current = { key: key, frame: frame, start_time: time, end_time: time, count: 1 }
        end
      end
      spans << current if current

      spans.filter_map do |span|
        duration = [
          (span[:end_time] - span[:start_time]) * MS_PER_SECOND,
          span[:count] * Catpm.config.stack_sample_interval * MS_PER_SECOND
        ].max
        next if duration < MIN_SEGMENT_DURATION_MS

        frame = span[:frame]
        path = frame.path.to_s

        {
          type: classify_path(path),
          detail: build_gem_detail(frame),
          duration: duration.round(2),
          offset: ((span[:start_time] - @request_start) * MS_PER_SECOND).round(2),
          started_at: span[:start_time]
        }
      end
    end

    def estimate_duration(group)
      [
        (group[:end_time] - group[:start_time]) * MS_PER_SECOND,
        group[:count] * Catpm.config.stack_sample_interval * MS_PER_SECOND
      ].max
    end

    def frame_key(frame)
      "#{frame.path}:#{frame.label}"
    end

    def classify_path(path)
      return 'code' if Fingerprint.app_frame?(path)

      gem = extract_gem_name(path)
      case gem
      when /\A(httpclient|net-http|faraday|httpx|typhoeus|excon|http)\z/ then 'http'
      when /\A(pg|mysql2|sqlite3|trilogy)\z/ then 'sql'
      when /\A(redis|dalli|hiredis)\z/ then 'cache'
      when /\A(aws-sdk|google-cloud|fog)\z/ then 'storage'
      when /\A(mail|net-smtp)\z/ then 'mailer'
      else 'gem'
      end
    end

    def build_app_detail(frame)
      path = frame.path.to_s
      short = path.sub(%r{.*/app/}, 'app/').sub(%r{.*/lib/}, 'lib/')
      "#{short} in #{frame.label}"
    end

    def build_gem_detail(frame)
      path = frame.path.to_s
      if Fingerprint.app_frame?(path)
        build_app_detail(frame)
      else
        gem = extract_gem_name(path) || 'unknown'
        "#{gem}: #{frame.label}"
      end
    end

    def extract_gem_name(path)
      if path =~ /\/gems\/([a-zA-Z0-9_-]+)-[\d.]+/
        $1
      end
    end
  end
end
