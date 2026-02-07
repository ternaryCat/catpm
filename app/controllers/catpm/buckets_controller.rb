# frozen_string_literal: true

module Catpm
  class BucketsController < ApplicationController
    def show
      @bucket = Catpm::Bucket.find(params[:id])
      @samples = @bucket.samples.order(duration: :desc).limit(50)
      @metadata = @bucket.parsed_metadata_sum
      @tdigest = @bucket.tdigest
    end
  end
end
