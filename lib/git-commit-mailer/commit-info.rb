# -*- coding: utf-8 -*-
#
# Copyright (C) 2009  Ryo Onodera <onodera@clear-code.com>
# Copyright (C) 2012-2014  Kouhei Sutou <kou@clear-code.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class GitCommitMailer
  class CommitInfo < Info
    class << self
      def unescape_file_path(file_path)
        if file_path =~ /\A"(.*)"\z/
          escaped_file_path = $1
          if escaped_file_path.respond_to?(:encoding)
            encoding = escaped_file_path.encoding
          else
            encoding = nil
          end
          unescaped_file_path = escaped_file_path.gsub(/\\\\/, '\\').
                                                  gsub(/\\\"/, '"').
                                                  gsub(/\\([0-9]{1,3})/) do
            $1.to_i(8).chr
          end
          unescaped_file_path.force_encoding(encoding) if encoding
          unescaped_file_path
        else
          file_path
        end
      end
    end

    attr_reader :mailer, :revision, :reference
    attr_reader :added_files, :copied_files, :deleted_files, :updated_files
    attr_reader :renamed_files, :type_changed_files, :diffs
    attr_reader :subject, :author_name, :author_email, :date, :summary
    attr_accessor :merge_status
    attr_writer :reference
    attr_reader :merge_revisions
    def initialize(mailer, reference, revision)
      @mailer = mailer
      @reference = reference
      @revision = revision

      @files = []
      @added_files = []
      @copied_files = []
      @deleted_files = []
      @updated_files = []
      @renamed_files = []
      @type_changed_files = []

      set_records
      parse_file_status
      parse_diff

      @merge_status = []
      @merge_revisions = []
    end

    def first_parent
      return nil if @parent_revisions.length.zero?

      @parent_revisions[0]
    end

    def other_parents
      return [] if @parent_revisions.length.zero?

      @parent_revisions[1..-1]
    end

    def merge?
      @parent_revisions.length >= 2
    end

    def message_id
      if merge?
        "<merge.#{@parent_revisions.first}.#{@revision}@#{self.class.host_name}>"
      else
        "<#{@revision}@#{self.class.host_name}>"
      end
    end

    def headers
      [
        "X-Git-Author: #{@author_name}",
        "X-Git-Revision: #{@revision}",
        # "X-Git-Repository: #{path}",
        "X-Git-Repository: XXX",
        "X-Git-Commit-Id: #{@revision}",
        "Message-ID: #{message_id}",
        *related_mail_headers
      ]
    end

    def related_mail_headers
      headers = []
      @merge_revisions.each do |merge_revision|
        merge_message_id = "<#{merge_revision}@#{self.class.host_name}>"
        headers << "References: #{merge_message_id}"
        headers << "In-Reply-To: #{merge_message_id}"
      end
      headers
    end

    def format_mail_subject
      affected_path_info = ""
      if @mailer.show_path?
        _affected_paths = affected_paths
        unless _affected_paths.empty?
          affected_path_info = " (#{_affected_paths.join(',')})"
        end
      end

      "[#{short_reference}#{affected_path_info}] " + subject
    end

    def format_mail_body_text
      TextMailBodyFormatter.new(self).format
    end

    def format_mail_body_html
      HTMLMailBodyFormatter.new(self).format
    end

    def short_revision
      GitCommitMailer.short_revision(@revision)
    end

    def file_index(name)
      @files.index(name)
    end

    def rss_title
      format_mail_subject
    end

    def rss_content
      "<pre>#{ERB::Util.h(format_mail_body_text)}</pre>"
    end

    private
    def sub_paths(prefix)
      prefixes = prefix.split(/\/+/)
      results = []
      @diffs.each do |diff|
        paths = diff.file_path.split(/\/+/)
        if prefixes.size < paths.size and prefixes == paths[0, prefixes.size]
          results << paths[prefixes.size]
        end
      end
      results
    end

    def affected_paths
      paths = []
      sub_paths = sub_paths('')
      paths.concat(sub_paths)
      paths.uniq
    end

    def set_records
      author_name, author_email, date, subject, parent_revisions =
        get_records(["%an", "%ae", "%at", "%s", "%P"])
      @author_name = author_name
      @author_email = author_email
      @date = Time.at(date.to_i)
      @subject = subject
      @parent_revisions = parent_revisions.split
      @summary = git("log -n 1 --pretty=format:%s%n%n%b #{@revision}")
    end

    def parse_diff
      @diffs = []
      output = []
      n_bytes = 0
      git("log -n 1 --pretty=format:'' -C -p #{@revision}") do |io|
        io.each_line do |line|
          n_bytes += line.bytesize
          break if n_bytes > mailer.max_diff_size
          utf8_line = force_utf8(line) || "(binary line)\n"
          output << utf8_line
        end
      end
      return if output.empty?

      output.shift if output.first.strip.empty?

      lines = []

      line = output.shift
      lines << line.chomp if line # take out the very first 'diff --git' header
      while line = output.shift
        line.chomp!
        case line
        when /\Adiff --git/
          @diffs << create_file_diff(lines)
          lines = [line]
        else
          lines << line
        end
      end

      # create the last diff terminated by the EOF
      @diffs << create_file_diff(lines) if lines.length > 0
    end

    def create_file_diff(lines)
      diff = FileDiff.new(@mailer, lines, @revision)
      diff.index = @files.index(diff.file_path)
      diff
    end

    def parse_file_status
      git("log -n 1 --pretty=format:'' -C --name-status #{@revision}").
      lines.each do |line|
        line.rstrip!
        next if line.empty?
        case line
        when /\A([^\t]*?)\t([^\t]*?)\z/
          status = $1
          file = CommitInfo.unescape_file_path($2)

          case status
          when /^A/ # Added
            @added_files << file
          when /^M/ # Modified
            @updated_files << file
          when /^D/ # Deleted
            @deleted_files << file
          when /^T/ # File Type Changed
            @type_changed_files << file
          else
            raise "unsupported status type: #{line.inspect}"
          end

          @files << file
        when /\A([^\t]*?)\t([^\t]*?)\t([^\t]*?)\z/
          status = $1
          from_file = CommitInfo.unescape_file_path($2)
          to_file = CommitInfo.unescape_file_path($3)

          case status
          when /^R/ # Renamed
            @renamed_files << [from_file, to_file]
          when /^C/ # Copied
            @copied_files << [from_file, to_file]
          else
            raise "unsupported status type: #{line.inspect}"
          end

          @files << to_file
        else
          raise "unsupported status type: #{line.inspect}"
        end
      end
    end

    def force_utf8(string)
      string.force_encoding("UTF-8")
      return string if string.valid_encoding?

      guess_encodings = [
        "Windows-31J",
        "EUC-JP",
      ]
      guess_encodings.each do |guess_encoding|
        string.force_encoding(guess_encoding)
        next unless string.valid_encoding?
        begin
          return string.encode("UTF-8")
        rescue EncodingError
        end
      end

      nil
    end
  end
end

require "git-commit-mailer/file-diff"
require "git-commit-mailer/mail-body-formatter"
require "git-commit-mailer/text-mail-body-formatter"
require "git-commit-mailer/html-mail-body-formatter"
