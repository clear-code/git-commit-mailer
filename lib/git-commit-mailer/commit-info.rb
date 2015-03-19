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
      "<#{@revision}@#{self.class.host_name}>"
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

    class MailBodyFormatter
      def initialize(info)
        @info = info
        @mailer = @info.mailer
      end

      def format
        ERB.new(template, nil, "<>").result(binding)
      end

      private
      def commit_url
        case @mailer.repository_browser
        when "github"
          user = @mailer.github_user
          repository = @mailer.github_repository
          return nil if user.nil? or repository.nil?
          base_url = @mailer.github_base_url
          revision = @info.revision
          "#{base_url}/#{user}/#{repository}/commit/#{revision}"
        when "github-wiki"
          file = (@info.updated_files + @info.added_files).first
          commit_file_url_github_wiki(file)
        when "gitlab"
          return nil if @mailer.gitlab_project_uri.nil?
          revision = @info.revision
          "#{@mailer.gitlab_project_uri}/commit/#{revision}"
        else
          nil
        end
      end

      def commit_file_url(file)
        case @mailer.repository_browser
        when "github"
          base_url = commit_url
          return nil if base_url.nil?
          index = @info.file_index(file)
          return nil if index.nil?
          "#{base_url}#diff-#{index}"
        when "github-wiki"
          commit_file_url_github_wiki(file)
        else
          nil
        end
      end

      def commit_file_url_github_wiki(file)
        return nil if file.nil?

        user = @mailer.github_user
        repository = @mailer.github_repository
        return nil if user.nil? or repository.nil?
        base_url = @mailer.github_base_url
        page_name = file.gsub(/\.[^.]+\z/, "")
        page_name_in_url = ERB::Util.u(page_name)
        revision = @info.revision
        "#{base_url}/#{user}/#{repository}/wiki/#{page_name_in_url}/#{revision}"
      end

      def commit_file_line_number_url(file, direction, line_number)
        base_url = commit_url
        return nil if base_url.nil?

        case @mailer.repository_browser
        when "github"
          index = @info.file_index(file)
          return nil if index.nil?
          url = "#{base_url}#L#{index}"
          url << ((direction == :from) ? "L" : "R")
          url << line_number.to_s
          url
        else
          nil
        end
      end
    end

    class TextMailBodyFormatter < MailBodyFormatter
      def format
        super.sub(/\n+\z/, "\n")
      end

      private
      def template
        <<-EOT
<%= @info.author_name %>\t<%= @mailer.format_time(@info.date) %>


  New Revision: <%= @info.revision %>
<%= format_commit_url %>

<% unless @info.merge_status.empty? %>
<%   @info.merge_status.each do |status| %>
  <%= status %>
<%   end %>

<% end %>
  Message:
<% @info.summary.rstrip.each_line do |line| %>
    <%= line.rstrip %>
<% end %>

<%= format_files("Added",        @info.added_files) %>
<%= format_files("Copied",       @info.copied_files) %>
<%= format_files("Removed",      @info.deleted_files) %>
<%= format_files("Modified",     @info.updated_files) %>
<%= format_files("Renamed",      @info.renamed_files) %>
<%= format_files("Type Changed", @info.type_changed_files) %>

<%= format_diff %>
EOT
      end

      def format_commit_url
        url = commit_url
        return "" if url.nil?
        "  #{url}\n"
      end

      def format_files(title, items)
        return "" if items.empty?

        formatted_files = "  #{title} files:\n"
        items.each do |item_name, new_item_name|
          if new_item_name.nil?
            formatted_files << "    #{item_name}\n"
          else
            formatted_files << "    #{new_item_name}\n"
            formatted_files << "      (from #{item_name})\n"
          end
        end
        formatted_files
      end

      def format_diff
        format_diffs.join("\n")
      end

      def format_diffs
        @info.diffs.collect do |diff|
          diff.format
        end
      end
    end

    class HTMLMailBodyFormatter < MailBodyFormatter
      include ERB::Util

      def format
        @indent_level = 0
        super
      end

      private
      def template
        <<-EOT
<!DOCTYPE html>
<html>
  <head>
  </head>
  <body>
    <%= dl_start %>
      <%= dt("Author") %>
      <%= dd(h("\#{@info.author_name} <\#{@info.author_email}>")) %>
      <%= dt("Date") %>
      <%= dd(h(@mailer.format_time(@info.date))) %>
      <%= dt("New Revision") %>
      <%= dd(format_revision) %>
<% unless @info.merge_status.empty? %>
      <%= dt("Merge") %>
      <%= dd_start %>
        <ul>
<%   @info.merge_status.each do |status| %>
          <li><%= h(status) %></li>
<%   end %>
        </ul>
      </dd>
<% end %>
      <%= dt("Message") %>
      <%= dd(pre(h(@info.summary.strip))) %>
<%= format_files("Added",        @info.added_files) %>
<%= format_files("Copied",       @info.copied_files) %>
<%= format_files("Removed",      @info.deleted_files) %>
<%= format_files("Modified",     @info.updated_files) %>
<%= format_files("Renamed",      @info.renamed_files) %>
<%= format_files("Type Changed", @info.type_changed_files) %>
    </dl>

<%= format_diffs %>
  </body>
</html>
EOT
      end

      def format_revision
        revision = @info.revision
        url = commit_url
        if url
          formatted_revision = "<a href=\"#{h(url)}\">#{h(revision)}</a>"
        else
          formatted_revision = h(revision)
        end
        formatted_revision
      end

      def format_files(title, items)
        return "" if items.empty?

        formatted_files = ""
        formatted_files << "      #{dt(h(title) + ' files')}\n"
        formatted_files << "      #{dd_start}\n"
        formatted_files << "        <ul>\n"
        items.each do |item_name, new_item_name|
          if new_item_name.nil?
            formatted_files << "          <li>#{format_file(item_name)}</li>\n"
          else
            formatted_files << "          <li>\n"
            formatted_files << "            #{format_file(new_item_name)}<br>\n"
            formatted_files << "            (from #{item_name})\n"
            formatted_files << "          </li>\n"
          end
        end
        formatted_files << "        </ul>\n"
        formatted_files << "      </dd>\n"
        formatted_files
      end

      def format_file(file)
        content = h(file)
        url = commit_file_url(file)
        if url
          content = tag("a", {"href" => url}, content)
        end
        content
      end

      def format_diffs
        return "" if @info.diffs.empty?

        formatted_diff = ""
        formatted_diff << "    #{div_diff_section_start}\n"
        @indent_level = 3
        @info.diffs.each do |diff|
          formatted_diff << "#{format_diff(diff)}\n"
        end
        formatted_diff << "    </div>\n"
        formatted_diff
      end

      def format_diff(diff)
        header_column = format_header_column(diff)
        from_line_column, to_line_column, content_column =
          format_body_columns(diff)

        table_diff do
          head = tag("thead") do
            tr_diff_header do
              tag("td", {"colspan" => "3"}) do
                pre_column(header_column)
              end
            end
          end

          body = tag("tbody") do
            tag("tr") do
              [
                th_diff_line_number {pre_column(from_line_column)},
                th_diff_line_number {pre_column(to_line_column)},
                td_diff_content     {pre_column(content_column)},
              ]
            end
          end

          [head, body]
        end
      end

      def format_header_column(diff)
        header_column = ""
        diff.format_header.each_line do |line|
          line = line.chomp
          case line
          when /^=/
            header_column << span_diff_header_mark(h(line))
          else
            header_column << span_diff_header(h(line))
          end
          header_column << "\n"
        end
        header_column
      end

      def format_body_columns(diff)
        from_line_column = ""
        to_line_column = ""
        content_column = ""
        file_path = diff.file_path
        diff.changes.each do |type, line_number, line|
          case type
          when :hunk_header
            from_line_number, to_line_number = line_number
            from_line_column << span_line_number_hunk_header(file_path, :from,
                                                             from_line_number)
            to_line_column << span_line_number_hunk_header(file_path, :to,
                                                           to_line_number)
            case line
            when /\A(@@[\s0-9\-+,]+@@\s*)(.+)(\s*)\z/
              hunk_info = $1
              context = $2
              formatted_line = h(hunk_info) + span_diff_context(h(context))
            else
              formatted_line = h(line)
            end
            content_column << span_diff_hunk_header(formatted_line)
          when :added
            from_line_column << span_line_number_nothing
            to_line_column << span_line_number_added(file_path, line_number)
            content_column << span_diff_added(h(line))
          when :deleted
            from_line_column << span_line_number_deleted(file_path, line_number)
            to_line_column << span_line_number_nothing
            content_column << span_diff_deleted(h(line))
          when :not_changed
            from_line_number, to_line_number = line_number
            from_line_column << span_line_number_not_changed(file_path, :from,
                                                             from_line_number)
            to_line_column << span_line_number_not_changed(file_path, :to,
                                                           to_line_number)
            content_column << span_diff_not_changed(h(line))
          end
          from_line_column << "\n"
          to_line_column << "\n"
          content_column << "\n"
        end
        [from_line_column, to_line_column, content_column]
      end

      def tag_start(name, attributes)
        start_tag = "<#{name}"
        unless attributes.empty?
          sorted_attributes = attributes.sort_by do |key, value|
            key
          end
          formatted_attributes = sorted_attributes.collect do |key, value|
            if value.is_a?(Hash)
              sorted_value = value.sort_by do |value_key, value_value|
                value_key
              end
              value = sorted_value.collect do |value_key, value_value|
                "#{value_key}: #{value_value}"
              end
            end
            if value.is_a?(Array)
              value = value.sort.join("; ")
            end
            "#{h(key)}=\"#{h(value)}\""
          end
          formatted_attributes = formatted_attributes.join(" ")
          start_tag << " #{formatted_attributes}"
        end
        start_tag << ">"
        start_tag
      end

      def tag(name, attributes={}, content=nil, &block)
        block_used = false
        if content.nil? and block_given?
          @indent_level += 1
          if block.arity == 1
            content = []
            yield(content)
          else
            content = yield
          end
          @indent_level -= 1
          block_used = true
        end
        content ||= ""
        if content.is_a?(Array)
          if block_used
            separator = "\n"
          else
            separator = ""
          end
          content = content.join(separator)
        end

        formatted_tag = ""
        formatted_tag << "  " * @indent_level if block_used
        formatted_tag << tag_start(name, attributes)
        formatted_tag << "\n" if block_used
        formatted_tag << content
        formatted_tag << "\n" + ("  " * @indent_level) if block_used
        formatted_tag << "</#{name}>"
        formatted_tag
      end

      def dl_start
        tag_start("dl",
                  "style" => {
                    "margin-left" => "2em",
                    "line-height" => "1.5",
                  })
      end

      def dt_margin
        8
      end

      def dt(content)
        tag("dt",
            {
              "style" => {
                "clear"       => "both",
                "float"       => "left",
                "width"       => "#{dt_margin}em",
                "font-weight" => "bold",
              },
            },
            content)
      end

      def dd_start
        tag_start("dd",
                  "style" => {
                    "margin-left" => "#{dt_margin + 0.5}em",
                  })
      end

      def dd(content)
        "#{dd_start}#{content}</dd>"
      end

      def border_styles
        {
          "border"      => "1px solid #aaa",
        }
      end

      def pre(content, styles={})
        font_families = [
          "Consolas", "Menlo", "\"Liberation Mono\"",
          "Courier", "monospace"
        ]
        pre_styles = {
          "font-family" => font_families.join(", "),
          "line-height" => "1.2",
          "padding"     => "0.5em",
          "width"       => "auto",
        }
        pre_styles = pre_styles.merge(border_styles)
        tag("pre", {"style" => pre_styles.merge(styles)}, content)
      end

      def div_diff_section_start
        tag_start("div",
                  "class" => "diff-section",
                  "style" => {
                    "clear" => "both",
                  })
      end

      def div_diff_start
        tag_start("div",
                  "class" => "diff",
                  "style" => {
                    "margin-left"  => "1em",
                    "margin-right" => "1em",
                  })
      end

      def table_diff(&block)
        styles = {
          "border-collapse" => "collapse",
        }
        tag("table",
            {
              "style" => border_styles.merge(styles),
            },
            &block)
      end

      def tr_diff_header(&block)
        tag("tr",
            {
              "class" => "diff-header",
              "style" => border_styles,
            },
            &block)
      end

      def th_diff_line_number(&block)
        tag("th",
            {
              "class" => "diff-line-number",
              "style" => border_styles,
            },
            &block)
      end

      def td_diff_content(&block)
        tag("td",
            {
              "class" => "diff-content",
              "style" => border_styles,
            },
            &block)
      end

      def pre_column(column)
        pre(column,
            "white-space" => "normal",
            "margin" => "0",
            "border" => "0")
      end

      def span_common_styles
        {
          "white-space" => "pre",
          "display"     => "block",
        }
      end

      def span_context_styles
        {
          "background-color" => "#ffffaa",
          "color"            => "#000000",
        }
      end

      def span_deleted_styles
        {
          "background-color" => "#ffaaaa",
          "color"            => "#000000",
        }
      end

      def span_added_styles
        {
          "background-color" => "#aaffaa",
          "color"            => "#000000",
        }
      end

      def span_line_number_styles
        span_common_styles
      end

      def span_line_number_nothing
        tag("span",
            {
              "class" => "diff-line-number-nothing",
              "style" => span_line_number_styles,
            },
            "&nbsp;")
      end

      def span_line_number_hunk_header(file_path, direction, offset)
        content = "..."
        url = commit_file_line_number_url(file_path, direction, offset - 1)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-hunk-header",
              "style" => span_line_number_styles,
            },
            content)
      end

      def span_line_number_deleted(file_path, line_number)
        content = h(line_number.to_s)
        url = commit_file_line_number_url(file_path, :from, line_number)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-deleted",
              "style" => span_line_number_styles.merge(span_deleted_styles),
            },
            content)
      end

      def span_line_number_added(file_path, line_number)
        content = h(line_number.to_s)
        url = commit_file_line_number_url(file_path, :to, line_number)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-added",
              "style" => span_line_number_styles.merge(span_added_styles),
            },
            content)
      end

      def span_line_number_not_changed(file_path, direction, line_number)
        content = h(line_number.to_s)
        url = commit_file_line_number_url(file_path, direction, line_number)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-not-changed",
              "style" => span_line_number_styles,
            },
            content)
      end

      def span_diff_styles
        span_common_styles
      end

      def span_diff_metadata_styles
        styles = {
          "background-color" => "#eaf2f5",
          "color"            => "#999999",
        }
        span_diff_styles.merge(styles)
      end

      def span_diff_header(content)
        tag("span",
            {
              "class" => "diff-header",
              "style" => span_diff_metadata_styles,
            },
            content)
      end

      def span_diff_header_mark(content)
        tag("span",
            {
              "class" => "diff-header-mark",
              "style" => span_diff_metadata_styles,
            },
            content)
      end

      def span_diff_hunk_header(content)
        tag("span",
            {
              "class" => "diff-hunk-header",
              "style" => span_diff_metadata_styles,
            },
            content)
      end

      def span_diff_context(content)
        tag("span",
            {
              "class" => "diff-context",
              "style" => span_context_styles,
            },
            content)
      end

      def span_diff_deleted(content)
        tag("span",
            {
              "class" => "diff-deleted",
              "style" => span_diff_styles.merge(span_deleted_styles),
            },
            content)
      end

      def span_diff_added(content)
        tag("span",
            {
              "class" => "diff-added",
              "style" => span_diff_styles.merge(span_added_styles),
            },
            content)
      end

      def span_diff_not_changed(content)
        tag("span",
            {
              "class" => "diff-not-changed",
              "style" => span_diff_styles,
            },
            content)
      end
    end
  end
end
