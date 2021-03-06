require "aws-sdk"

require "tus/info"
require "tus/errors"

require "json"
require "cgi"
require "fiber"
require "stringio"

Aws.eager_autoload!(services: ["S3"])

module Tus
  module Storage
    class S3
      MIN_PART_SIZE = 5 * 1024 * 1024 # 5MB is the minimum part size for S3 multipart uploads

      attr_reader :client, :bucket, :prefix, :upload_options

      def initialize(bucket:, prefix: nil, upload_options: {}, thread_count: 10, **client_options)
        resource = Aws::S3::Resource.new(**client_options)

        @client         = resource.client
        @bucket         = resource.bucket(bucket) or fail(ArgumentError, "the :bucket option was nil")
        @prefix         = prefix
        @upload_options = upload_options
        @thread_count   = thread_count
      end

      def create_file(uid, info = {})
        tus_info = Tus::Info.new(info)

        options = upload_options.dup
        options[:content_type] = tus_info.metadata["content_type"]

        if filename = tus_info.metadata["filename"]
          # Aws-sdk doesn't sign non-ASCII characters correctly, and browsers
          # will automatically URI-decode filenames.
          filename = CGI.escape(filename).gsub("+", " ")

          options[:content_disposition] ||= "inline"
          options[:content_disposition]  += "; filename=\"#{filename}\""
        end

        multipart_upload = object(uid).initiate_multipart_upload(options)

        info["multipart_id"]    = multipart_upload.id
        info["multipart_parts"] = []

        multipart_upload
      end

      def concatenate(uid, part_uids, info = {})
        multipart_upload = create_file(uid, info)

        objects = part_uids.map { |part_uid| object(part_uid) }
        parts   = copy_parts(objects, multipart_upload)

        info["multipart_parts"].concat parts

        finalize_file(uid, info)

        delete(part_uids.flat_map { |part_uid| [object(part_uid), object("#{part_uid}.info")] })

        # Tus server requires us to return the size of the concatenated file.
        object = client.head_object(bucket: bucket.name, key: object(uid).key)
        object.content_length
      rescue => error
        abort_multipart_upload(multipart_upload) if multipart_upload
        raise error
      end

      def patch_file(uid, input, info = {})
        tus_info = Tus::Info.new(info)

        upload_id      = info["multipart_id"]
        part_offset    = info["multipart_parts"].count
        bytes_uploaded = 0

        jobs = []
        chunk = StringIO.new(input.read(MIN_PART_SIZE).to_s)

        loop do
          next_chunk = StringIO.new(input.read(MIN_PART_SIZE).to_s)

          # merge next chunk into previous if it's smaller than minimum chunk size
          if next_chunk.size < MIN_PART_SIZE
            chunk = StringIO.new(chunk.string + next_chunk.string)
            next_chunk.close
            next_chunk = nil
          end

          # abort if chunk is smaller than 5MB and is not the last chunk
          if chunk.size < MIN_PART_SIZE
            break if (tus_info.length && tus_info.offset) &&
                     chunk.size + tus_info.offset < tus_info.length
          end

          thread = upload_part_thread(chunk, uid, upload_id, part_offset += 1)
          jobs << [thread, chunk]

          chunk = next_chunk or break
        end

        jobs.each do |thread, body|
          info["multipart_parts"] << thread.value
          bytes_uploaded += body.size
          body.close
        end

        bytes_uploaded
      end

      def finalize_file(uid, info = {})
        upload_id = info["multipart_id"]
        parts = info["multipart_parts"].map do |part|
          { part_number: part["part_number"], etag: part["etag"] }
        end

        multipart_upload = object(uid).multipart_upload(upload_id)
        multipart_upload.complete(multipart_upload: { parts: parts })

        info.delete("multipart_id")
        info.delete("multipart_parts")
      end

      def read_info(uid)
        response = object("#{uid}.info").get
        JSON.parse(response.body.string)
      rescue Aws::S3::Errors::NoSuchKey
        raise Tus::NotFound
      end

      def update_info(uid, info)
        object("#{uid}.info").put(body: info.to_json)
      end

      def get_file(uid, info = {}, range: nil)
        tus_info = Tus::Info.new(info)

        length = range ? range.size : tus_info.length
        range  = "bytes=#{range.begin}-#{range.end}" if range
        chunks = object(uid).enum_for(:get, range: range)

        # We return a response object that responds to #each, #length and #close,
        # which the tus server can return directly as the Rack response.
        Response.new(chunks: chunks, length: length)
      end

      def delete_file(uid, info = {})
        if info["multipart_id"]
          multipart_upload = object(uid).multipart_upload(info["multipart_id"])
          abort_multipart_upload(multipart_upload)

          delete [object("#{uid}.info")]
        else
          delete [object(uid), object("#{uid}.info")]
        end
      end

      def expire_files(expiration_date)
        old_objects = bucket.objects.select do |object|
          object.last_modified <= expiration_date
        end

        delete(old_objects)

        bucket.multipart_uploads.each do |multipart_upload|
          # no need to check multipart uploads initiated before expiration date
          next if multipart_upload.initiated > expiration_date

          most_recent_part = multipart_upload.parts.sort_by(&:last_modified).last
          if most_recent_part.nil? || most_recent_part.last_modified <= expiration_date
            abort_multipart_upload(multipart_upload)
          end
        end
      end

      private

      def upload_part_thread(body, key, upload_id, part_number)
        Thread.new { upload_part(body, key, upload_id, part_number) }
      end

      def upload_part(body, key, upload_id, part_number)
        multipart_upload = object(key).multipart_upload(upload_id)
        multipart_part   = multipart_upload.part(part_number)

        response = multipart_part.upload(body: body)

        { "part_number" => part_number, "etag" => response.etag }
      end

      def delete(objects)
        # S3 can delete maximum of 1000 objects in a single request
        objects.each_slice(1000) do |objects_batch|
          delete_params = { objects: objects_batch.map { |object| { key: object.key } } }
          bucket.delete_objects(delete: delete_params)
        end
      end

      # In order to ensure the multipart upload was successfully aborted,
      # we need to check whether all parts have been deleted, and retry
      # the abort if the list is nonempty.
      def abort_multipart_upload(multipart_upload)
        loop do
          multipart_upload.abort
          break unless multipart_upload.parts.any?
        end
      rescue Aws::S3::Errors::NoSuchUpload
        # multipart upload was successfully aborted or doesn't exist
      end

      def copy_parts(objects, multipart_upload)
        parts = compute_parts(objects, multipart_upload)
        queue = parts.inject(Queue.new) { |queue, part| queue << part }

        threads = @thread_count.times.map { copy_part_thread(queue) }

        threads.flat_map(&:value).sort_by { |part| part["part_number"] }
      end

      def compute_parts(objects, multipart_upload)
        objects.map.with_index do |object, idx|
          {
            bucket:      multipart_upload.bucket_name,
            key:         multipart_upload.object_key,
            upload_id:   multipart_upload.id,
            copy_source: [object.bucket_name, object.key].join("/"),
            part_number: idx + 1,
          }
        end
      end

      def copy_part_thread(queue)
        Thread.new do
          begin
            results = []
            loop do
              part = queue.deq(true) rescue break
              results << copy_part(part)
            end
            results
          rescue
            queue.clear
            raise
          end
        end
      end

      def copy_part(part)
        response = client.upload_part_copy(part)

        { "part_number" => part[:part_number], "etag" => response.copy_part_result.etag }
      end

      def object(key)
        bucket.object([*prefix, key].join("/"))
      end

      class Response
        def initialize(chunks:, length:)
          @chunks = chunks
          @length = length
        end

        def length
          @length
        end

        def each
          return enum_for(__method__) unless block_given?

          while (chunk = chunks_fiber.resume)
            yield chunk
          end
        end

        def close
          chunks_fiber.resume(:close) if chunks_fiber.alive?
        end

        private

        def chunks_fiber
          @chunks_fiber ||= Fiber.new do
            @chunks.each do |chunk|
              action = Fiber.yield chunk
              break if action == :close
            end
            nil
          end
        end
      end
    end
  end
end
