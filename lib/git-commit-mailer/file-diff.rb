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
  class FileDiff
    CHANGED_TYPE = {
      :added    => "Added",
      :modified => "Modified",
      :deleted  => "Deleted",
      :copied   => "Copied",
      :renamed  => "Renamed",
    }

    attr_reader :changes
    attr_accessor :index
    def initialize(mailer, lines, revision)
      @mailer = mailer
      @index = nil
      @body = ''
      @changes = []

      @type = :modified
      @is_binary = false
      @is_mode_changed = false

      @old_blob = @new_blob = nil

      parse_header(lines)
      detect_metadata(revision)
      parse_extended_headers(lines)
      parse_body(lines)
    end

    def file_path
      @to_file
    end

    def format_header
      header = "  #{CHANGED_TYPE[@type]}: #{@to_file} "
      header << "(+#{@added_line} -#{@deleted_line})"
      header << "#{format_file_mode}#{format_similarity_index}\n"
      header << "  Mode: #{@old_mode} -> #{@new_mode}\n" if @is_mode_changed
      header << diff_separator
      header
    end

    def format
      formatted_diff = format_header

      if @mailer.add_diff?
        formatted_diff << headers + @body
      else
        formatted_diff << git_command
      end

      formatted_diff
    end

    private
    def extract_file_path(file_path)
      case CommitInfo.unescape_file_path(file_path)
      when /\A[ab]\/(.*)\z/
        $1
      else
        raise "unknown file path format: #{@to_file}"
      end
    end

    def parse_header(lines)
      line = lines.shift.strip
      if line =~ /\Adiff --git ("?a\/.*) ("?b\/.*)/
        @from_file = extract_file_path($1)
        @to_file = extract_file_path($2)
      else
        raise "Unexpected diff header format: #{line}"
      end
    end

    def detect_metadata(revision)
      @new_revision = revision
      @new_date = Time.at(@mailer.get_record(@new_revision, "%at").to_i)

      begin
        @old_revision = @mailer.parent_commit(revision)
        @old_date = Time.at(@mailer.get_record(@old_revision, "%at").to_i)
      rescue NoParentCommit
        @old_revision = '0' * 40
        @old_date = nil
      end
      # @old_revision = @mailer.parent_commit(revision)
    end

    def parse_ordinary_change(line)
      case line
      when /\A--- (a\/.*|"a\/.*"|\/dev\/null)\z/
        @minus_file = CommitInfo.unescape_file_path($1)
        @type = :added if $1 == '/dev/null'
      when /\A\+\+\+ (b\/.*|"b\/.*"|\/dev\/null)\z/
        @plus_file = CommitInfo.unescape_file_path($1)
        @type = :deleted if $1 == '/dev/null'
      when /\Aindex ([0-9a-f]{7,})\.\.([0-9a-f]{7,})/
        @old_blob = $1
        @new_blob = $2
      else
        return false
      end
      true
    end

    def parse_add_and_remove(line)
      case line
      when /\Anew file mode (.*)\z/
        @type = :added
        @new_file_mode = $1
      when /\Adeleted file mode (.*)\z/
        @type = :deleted
        @deleted_file_mode = $1
      else
        return false
      end
      true
    end

    def parse_copy_and_rename(line)
      case line
      when /\Arename (from|to) (.*)\z/
        @type = :renamed
      when /\Acopy (from|to) (.*)\z/
        @type = :copied
      when /\Asimilarity index (.*)%\z/
        @similarity_index = $1.to_i
      else
        return false
      end
      true
    end

    def parse_binary_file_change(line)
      if line =~ /\ABinary files (.*) and (.*) differ\z/
        @is_binary = true
        if $1 == '/dev/null'
          @type = :added
        elsif $2 == '/dev/null'
          @type = :deleted
        else
          @type = :modified
        end
        true
      else
        false
      end
    end

    def parse_mode_change(line)
      case line
      when /\Aold mode (.*)\z/
        @old_mode = $1
        @is_mode_changed = true
      when /\Anew mode (.*)\z/
        @new_mode = $1
        @is_mode_changed = true
      else
        return false
      end
      true
    end

    def parse_extended_headers(lines)
      line = lines.shift
      while line != nil and not line =~ /\A@@/
        is_parsed = false
        is_parsed ||= parse_ordinary_change(line)
        is_parsed ||= parse_add_and_remove(line)
        is_parsed ||= parse_copy_and_rename(line)
        is_parsed ||= parse_binary_file_change(line)
        is_parsed ||= parse_mode_change(line)
        unless is_parsed
          raise "unexpected extended line header: " + line
        end

        line = lines.shift
      end
      lines.unshift(line) if line
    end

    def parse_body(lines)
      @added_line = @deleted_line = 0
      from_offset = 0
      to_offset = 0
      lines.each do |line|
        case line
        when /\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)?/
          from_offset = $1.to_i
          to_offset = $2.to_i
          @changes << [:hunk_header, [from_offset, to_offset], line]
        when /\A\+/
          @added_line += 1
          @changes << [:added, to_offset, line]
          to_offset += 1
        when /\A\-/
          @deleted_line += 1
          @changes << [:deleted, from_offset, line]
          from_offset += 1
        else
          @changes << [:not_changed, [from_offset, to_offset], line]
          from_offset += 1
          to_offset += 1
        end

        @body << line + "\n"
      end
    end

    def format_date(date)
      date.strftime('%Y-%m-%d %X %z')
    end

    def format_old_date
      format_date(@old_date)
    end

    def format_new_date
      format_date(@new_date)
    end

    def short_old_revision
      GitCommitMailer.short_revision(@old_revision)
    end

    def short_new_revision
      GitCommitMailer.short_revision(@new_revision)
    end

    def format_blob(blob)
      if blob
        " (#{blob})"
      else
        ""
      end
    end

    def format_new_blob
      format_blob(@new_blob)
    end

    def format_old_blob
      format_blob(@old_blob)
    end

    def format_old_date_and_blob
      format_old_date + format_old_blob
    end

    def format_new_date_and_blob
      format_new_date + format_new_blob
    end

    def from_header
      "--- #{@from_file}    #{format_old_date_and_blob}\n"
    end

    def to_header
      "+++ #{@to_file}    #{format_new_date_and_blob}\n"
    end

    def headers
      if @is_binary
        "(Binary files differ)\n"
      else
        if (@type == :renamed || @type == :copied) && @similarity_index == 100
          return ""
        end

        case @type
        when :added
          "--- /dev/null\n" + to_header
        when :deleted
          from_header + "+++ /dev/null\n"
        else
          from_header + to_header
        end
      end
    end

    def git_command
      case @type
      when :added
        command = "show"
        args = ["#{short_new_revision}:#{@to_file}"]
      when :deleted
        command = "show"
        args = ["#{short_old_revision}:#{@to_file}"]
      when :modified
        command = "diff"
        args = [short_old_revision, short_new_revision, "--", @to_file]
      when :renamed
        command = "diff"
        args = [
          "-C", "--diff-filter=R",
          short_old_revision, short_new_revision, "--",
          @from_file, @to_file,
        ]
      when :copied
        command = "diff"
        args = [
          "-C", "--diff-filter=C",
          short_old_revision, short_new_revision, "--",
          @from_file, @to_file,
        ]
      else
        raise "unknown diff type: #{@type}"
      end

      command += " #{args.join(' ')}" unless args.empty?
      "    % git #{command}\n"
    end

    def format_file_mode
      case @type
      when :added
        " #{@new_file_mode}"
      when :deleted
        " #{@deleted_file_mode}"
      else
        ""
      end
    end

    def format_similarity_index
      if @type == :renamed or @type == :copied
        " #{@similarity_index}%"
      else
        ""
      end
    end

    def diff_separator
      "#{"=" * 67}\n"
    end
  end
end
