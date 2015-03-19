class GitCommitMailer
  class Info
    class << self
      def host_name
        @@host_name ||= Socket.gethostbyname(Socket.gethostname).first
      end

      def host_name=(name)
        @@host_name = name
      end
    end

    def git(command, &block)
      @mailer.git(command, &block)
    end

    def get_record(record)
      @mailer.get_record(@revision, record)
    end

    def get_records(records)
      @mailer.get_records(@revision, records)
    end

    def short_reference
      @reference.sub(/\A.*\/.*\//, '')
    end

    def short_revision
      @revision[0, 7]
    end
  end
end
