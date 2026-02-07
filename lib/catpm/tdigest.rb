# frozen_string_literal: true

module Catpm
  # Minimal TDigest implementation for percentile estimation.
  # Based on the merging digest variant of the t-digest algorithm
  # by Ted Dunning (https://github.com/tdunning/t-digest).
  #
  # Provides accurate percentile estimates (p50, p95, p99) using
  # fixed memory (~1-3 KB serialized). Supports lossless merging
  # of two digests.
  class TDigest
    Centroid = Struct.new(:mean, :weight)

    COMPRESSION = 100 # Controls accuracy vs. memory trade-off

    attr_reader :count

    def initialize(compression: COMPRESSION)
      @compression = compression
      @centroids = []
      @count = 0
      @min = Float::INFINITY
      @max = -Float::INFINITY
      @buffer = []
      @buffer_limit = @compression * 5
    end

    def add(value, weight = 1)
      value = value.to_f
      @buffer << Centroid.new(value, weight)
      @count += weight
      @min = value if value < @min
      @max = value if value > @max
      flush_buffer if @buffer.size >= @buffer_limit
      self
    end

    def percentile(p)
      raise ArgumentError, "percentile must be between 0 and 1" unless (0..1).cover?(p)
      return nil if @count == 0

      flush_buffer unless @buffer.empty?
      return @centroids.first.mean if @centroids.size == 1

      target = p * @count
      cumulative = 0.0

      @centroids.each_with_index do |centroid, i|
        lower = cumulative
        upper = cumulative + centroid.weight

        if target < lower + centroid.weight / 2.0
          if i == 0
            return interpolate(@min, centroid.mean, target / (centroid.weight / 2.0))
          else
            prev = @centroids[i - 1]
            prev_upper = lower
            prev_mid = prev_upper - prev.weight / 2.0
            curr_mid = lower + centroid.weight / 2.0
            return interpolate(prev.mean, centroid.mean,
              (target - prev_mid) / (curr_mid - prev_mid))
          end
        end

        cumulative = upper
      end

      @centroids.last.mean
    end

    def merge(other)
      return self if other.nil? || other.count == 0

      other.send(:flush_buffer) unless other.send(:buffer).empty?
      other.send(:centroids).each do |c|
        add(c.mean, c.weight)
      end
      self
    end

    def empty?
      @count == 0
    end

    # Binary serialization: [compression(f64), count(u64), n_centroids(u32), min(f64), max(f64), (mean(f64), weight(u32))...]
    def serialize
      flush_buffer unless @buffer.empty?

      parts = []
      parts << [@compression].pack("E")      # f64 little-endian
      parts << [@count].pack("Q<")            # u64 little-endian
      parts << [@centroids.size].pack("V")    # u32 little-endian
      parts << [@min].pack("E")               # f64
      parts << [@max].pack("E")               # f64

      @centroids.each do |c|
        parts << [c.mean].pack("E")           # f64
        parts << [c.weight.to_i].pack("V")    # u32
      end

      parts.join.b
    end

    def self.deserialize(blob)
      return new if blob.nil? || blob.empty?

      blob = blob.b
      offset = 0

      compression = blob[offset, 8].unpack1("E"); offset += 8
      count = blob[offset, 8].unpack1("Q<");       offset += 8
      n = blob[offset, 4].unpack1("V");            offset += 4
      min = blob[offset, 8].unpack1("E");          offset += 8
      max = blob[offset, 8].unpack1("E");          offset += 8

      digest = new(compression: compression.to_i)
      digest.instance_variable_set(:@count, count)
      digest.instance_variable_set(:@min, min)
      digest.instance_variable_set(:@max, max)

      centroids = []
      n.times do
        mean = blob[offset, 8].unpack1("E");   offset += 8
        weight = blob[offset, 4].unpack1("V");  offset += 4
        centroids << Centroid.new(mean, weight)
      end
      digest.instance_variable_set(:@centroids, centroids)

      digest
    end

    private

    attr_reader :centroids, :buffer

    def flush_buffer
      return if @buffer.empty?

      all = @centroids + @buffer
      @buffer = []
      all.sort_by!(&:mean)

      merged = []
      weight_so_far = 0

      all.each do |centroid|
        if merged.empty?
          merged << Centroid.new(centroid.mean, centroid.weight)
        else
          last = merged.last
          q = (weight_so_far + last.weight / 2.0) / @count
          limit = 4.0 * @count * q * (1 - q) / @compression

          if last.weight + centroid.weight <= limit
            # Merge into existing centroid
            new_weight = last.weight + centroid.weight
            last.mean = (last.mean * last.weight + centroid.mean * centroid.weight) / new_weight
            last.weight = new_weight
          else
            weight_so_far += last.weight
            merged << Centroid.new(centroid.mean, centroid.weight)
          end
        end
      end

      @centroids = merged
    end

    def interpolate(a, b, fraction)
      fraction = fraction.clamp(0.0, 1.0)
      a + (b - a) * fraction
    end
  end
end
