require 'date'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength
module Shoryuken
  module CLI
    class SQS < Base
      namespace :sqs

      no_commands do
        def normalize_dump_message(message)
          message[:id] = message.delete(:message_id)
          message[:message_body] = message.delete(:body)
          message.delete(:receipt_handle)
          message.delete(:md5_of_body)
          message.delete(:md5_of_message_attributes)
          message
        end

        def sqs
          @_sqs ||= Aws::SQS::Client.new
        end

        def find_queue_url(queue_name_prefix)
          urls = sqs.list_queues(queue_name_prefix: queue_name_prefix).queue_urls

          if urls.size > 1
            fail_task "There's more than one queue starting with #{queue_name_prefix}: #{urls.join(', ')}"
          end

          urls.first
        end

        def batch_delete(queue_url, messages)
          messages.to_a.flatten.each_slice(10) do |batch|
            sqs.delete_message_batch(
              queue_url: queue_url,
              entries: batch.map { |message| { id: message.message_id, receipt_handle: message.receipt_handle } }
            ).failed.any? do |failure|
              say "Could not delete #{failure.id}, code: #{failure.code}", :yellow
            end
          end
        end

        def find_all(queue_url, limit, &block)
          count = 0
          batch_size = limit > 10 ? 10 : limit

          loop do
            n = limit - count
            batch_size = n if n < batch_size

            messages = sqs.receive_message(
              queue_url: queue_url,
              max_number_of_messages: batch_size,
              message_attribute_names: ['All']
            ).messages

            messages.each { |m| yield m }

            count += messages.size

            break if count >= limit
            break if messages.empty?
          end

          count
        end

        def dump_file(path, queue_name)
          File.join(path, "#{queue_name}-#{Date.today}.jsonl")
        end
      end

      desc 'ls [QUEUE-NAME-PREFIX]', 'List queues'
      def ls(queue_name_prefix = '')
        attrs = %w(QueueArn ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible LastModifiedTimestamp)

        urls = sqs.list_queues(queue_name_prefix: queue_name_prefix).queue_urls

        entries = urls.map { |u| sqs.get_queue_attributes(queue_url: u, attribute_names: attrs).attributes }.map do |q|
          [
            q['QueueArn'].split(':').last,
            q['ApproximateNumberOfMessages'],
            q['ApproximateNumberOfMessagesNotVisible'],
            Time.at(q['LastModifiedTimestamp'].to_i)
          ]
        end

        entries.unshift(['Queue', 'Messages Available', 'Messages Inflight', 'Last Modified'])

        print_table(entries)
      end

      desc 'dump QUEUE-NAME', 'Dump messages from a queue into a JSON lines file'
      method_option :number, aliases: '-n', type: :numeric, default: Float::INFINITY, desc: 'number of messages to dump'
      method_option :path,   aliases: '-p', type: :string,  default: './',            desc: 'path to save the dump file'
      method_option :delete, aliases: '-d', type: :boolean, default: true,            desc: 'delete from the queue'
      def dump(queue_name)
        path = dump_file(options[:path], queue_name)

        fail_task "File #{path} already exists" if File.exist?(path)

        url = find_queue_url(queue_name)

        delete_batch = []

        file = nil

        count = find_all(url, options[:number]) do |m|
          file ||= File.open(path, 'w')

          file.puts(JSON.dump(m.to_h))

          delete_batch << messages if options[:delete]
        end

        batch_delete(url, delete_batch) if options[:delete]

        if count.zero?
          say "Queue #{queue_name} is empty", :yellow
        else
          say "Dump saved in #{path} with #{count} messages", :green
        end
      ensure
        file.close if file
      end

      desc 'requeue QUEUE-NAME PATH', 'Requeue messages from a dump file'
      def requeue(queue_name, path)
        fail_task "Path #{path} not found" unless File.exist?(path)

        messages = File.readlines(path).map { |line| JSON.parse(line, symbolize_names: true) }

        url = find_queue_url(queue_name)

        messages.map(&method(:normalize_dump_message)).each_slice(10) do |batch|
          sqs.send_message_batch(queue_url: url, entries: batch).failed.any? do |failure|
            say "Could not requeue #{failure.id}, code: #{failure.code}", :yellow
          end
        end
      end
    end
  end
end
