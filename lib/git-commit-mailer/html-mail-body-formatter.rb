# -*- coding: utf-8 -*-
#
# Copyright (C) 2009  Ryo Onodera <onodera@clear-code.com>
# Copyright (C) 2012-2015  Kouhei Sutou <kou@clear-code.com>
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

require "digest/md5"

require "diff/lcs"

class GitCommitMailer
  class HTMLMailBodyFormatter < MailBodyFormatter
    include ERB::Util

    def format
      @indent_level = 0
      super
    end

    private
    def template
      <<-TEMPLATE
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
<% unless @info.merge_messages.empty? %>
      <%= dt("Merge") %>
      <%= dd_start %>
        <ul>
<%   @info.merge_messages.each do |message| %>
          <li><%= format_message(message) %></li>
<%   end %>
        </ul>
      </dd>
<% end %>
      <%= dt("Message") %>
      <%= dd(pre(format_message(@info.summary))) %>
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
      TEMPLATE
    end

    def format_revision
      revision = @info.revision
      url = commit_url
      if url
        formatted_revision = tag("a", {"href" => url}, h(revision))
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
      content_lines = []

      file_path = diff.file_path
      diff.changes.each do |type, line_number, line|
        case type
        when :hunk_header
          from_line_number, to_line_number = line_number
          from_line_column << span_line_number_hunk_header(file_path, :from,
                                                           from_line_number)
          to_line_column << span_line_number_hunk_header(file_path, :to,
                                                         to_line_number)

          flush_content_lines(content_column, content_lines)
          case line
          when /\A(@@[\s0-9\-+,]+@@\s*)(.+)(\s*)\z/
            hunk_info = $1
            context = $2
            formatted_line = h(hunk_info) + span_diff_context(h(context))
          else
            formatted_line = h(line)
          end
          content_column << span_diff_hunk_header(formatted_line) << "\n"
        when :added
          from_line_column << span_line_number_nothing
          to_line_column << span_line_number_added(file_path, line_number)
          content_lines << [:added, line]
        when :deleted
          from_line_column << span_line_number_deleted(file_path, line_number)
          to_line_column << span_line_number_nothing
          content_lines << [:deleted, line]
        when :not_changed
          from_line_number, to_line_number = line_number
          from_line_column << span_line_number_not_changed(file_path, :from,
                                                           from_line_number)
          to_line_column << span_line_number_not_changed(file_path, :to,
                                                         to_line_number)
          flush_content_lines(content_column, content_lines)
          content_column << span_diff_not_changed(h(line)) << "\n"
        end
        from_line_column << "\n"
        to_line_column << "\n"
      end
      flush_content_lines(content_column, content_lines)
      [from_line_column, to_line_column, content_column]
    end

    def flush_content_lines(column, lines)
      return if lines.empty?

      added_lines = []
      deleted_lines = []
      lines.each do |type, line|
        if type == :added
          added_lines << line
        else
          deleted_lines << line
        end
      end

      if added_lines.size == deleted_lines.size
        nth_added = 0
        nth_deleted = 0
        lines.each do |type, line|
          if type == :added
            deleted_line = deleted_lines[nth_added]
            formatted_added_line = format_added_words(line, deleted_line)
            column << span_diff_added(formatted_added_line) << "\n"
            nth_added += 1
          else
            added_line = added_lines[nth_deleted]
            formatted_deleted_line = format_deleted_words(line, added_line)
            column << span_diff_deleted(formatted_deleted_line) << "\n"
            nth_deleted += 1
          end
        end
      else
        lines.each do |type, line|
          if type == :added
            column << span_diff_added(h(line)) << "\n"
          else
            column << span_diff_deleted(h(line)) << "\n"
          end
        end
      end
      lines.clear
    end

    def format_changed_words(from_line, to_line, &formatter)
      line = h(from_line[0, 1])
      changed_chars = ""

      flush_changed_chars = lambda do
        unless changed_chars.empty?
          line << formatter.call(h(changed_chars))
          changed_chars.clear
        end
      end

      Diff::LCS.sdiff(from_line[1..-1], to_line[1..-1]).each do |diff|
        action, from, _to = *diff
        _from_nth, from_char = from
        next if from_char.nil?

        case action
        when "="
          flush_changed_chars.call
          line << h(from_char)
        when "!", "-"
          changed_chars << from_char
        when "+"
          flush_changed_chars.call
        end
      end
      flush_changed_chars.call

      line
    end

    def format_added_words(added_line, deleted_line)
      format_changed_words(added_line, deleted_line) do |chars|
        span_diff_added_word(chars)
      end
    end

    def format_deleted_words(deleted_line, added_line)
      format_changed_words(deleted_line, added_line) do |chars|
        span_diff_deleted_word(chars)
      end
    end

    def format_message(message)
      message = message.strip
      case @mailer.repository_browser
      when "github"
        format_message_github(message)
      else
        h(message)
      end
    end

    PATTERN_HTML_SPECIAL_CHARACTER = /['&\"<>]/
    PATTERN_EMAIL = /[\da-zA-Z\-_]+@[\da-zA-Z\-_.]+/
    GITHUB_MARKUP_PATTERN_GH_ISSUE = /GH-\d+/
    GITHUB_MARKUP_PATTERN_ISSUE = /\#\d+/
    GITHUB_MARKUP_PATTERN_COMMIT = /[\da-fA-F]{7,}/
    GITHUB_MARKUP_PATTERN_MENTION = /@[\da-zA-Z\-]+/
    def format_message_github(message)
      message.gsub(/
                     #{PATTERN_HTML_SPECIAL_CHARACTER}|
                     #{PATTERN_EMAIL}|
                     #{GITHUB_MARKUP_PATTERN_GH_ISSUE}|
                     #{GITHUB_MARKUP_PATTERN_ISSUE}|
                     #{GITHUB_MARKUP_PATTERN_COMMIT}|
                     #{GITHUB_MARKUP_PATTERN_MENTION}
                   /x) do |matched|
        case matched
        when /\A#{PATTERN_HTML_SPECIAL_CHARACTER}\z/
          h(matched)
        when /\A#{PATTERN_EMAIL}\z/
          h(matched)
        when /\A#{GITHUB_MARKUP_PATTERN_GH_ISSUE}\z/
          issue_number = matched.gsub(/\AGH-/, "")
          tag("a",
              {
                "href" => github_issue_url(issue_number),
              },
              h(matched))
        when /\A#{GITHUB_MARKUP_PATTERN_ISSUE}\z/
          issue_number = matched.gsub(/\A\#/, "")
          tag("a",
              {
                "href" => github_issue_url(issue_number),
              },
              h(matched))
        when /\A#{GITHUB_MARKUP_PATTERN_COMMIT}\z/
          revision = matched
          tag("a",
              {
                "href" => commit_url_github(revision),
              },
              h(matched))
        when /\A#{GITHUB_MARKUP_PATTERN_MENTION}\z/
          user_name = matched.gsub(/\A@/, "")
          tag("a",
              {
                "href" => user_url_github(user_name),
              },
              h(matched))
        else
          h(matched)
        end
      end
    end

    def github_issue_url(id)
      "#{@mailer.github_base_url}/#{@mailer.github_user}/#{@mailer.github_repository}/issues/#{id}"
    end

    def user_url_github(name)
      "#{@mailer.github_base_url}/#{name}"
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
        "background-color" => "#ffdddd",
        "color"            => "#000000",
      }
    end

    def span_deleted_word_styles
      {
        "background-color" => "#f8cbcb",
        "color"            => "#000000",
      }
    end

    def span_added_styles
      {
        "background-color" => "#dbffdb",
        "color"            => "#000000",
      }
    end

    def span_added_word_styles
      {
        "background-color" => "#a6f3a6",
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
      if offset <= 1
        offset_omitted = nil
      else
        offset_omitted = offset - 1
      end
      url = commit_file_line_number_url(file_path, direction, offset_omitted)
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

    def span_diff_deleted_word(content)
      tag("span",
          {
            "class" => "diff-deleted-word",
            "style" => span_deleted_word_styles,
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

    def span_diff_added_word(content)
      tag("span",
          {
            "class" => "diff-added-word",
            "style" => span_added_word_styles,
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

    def commit_file_url(file)
      case @mailer.repository_browser
      when "github"
        base_url = commit_url
        return nil if base_url.nil?
        file_md5 = Digest::MD5.hexdigest(file)
        "#{base_url}#diff-#{file_md5}"
      when "github-wiki"
        commit_file_url_github_wiki(file)
      else
        nil
      end
    end

    def commit_file_line_number_url(file, direction, line_number)
      base_url = commit_url
      return nil if base_url.nil?

      case @mailer.repository_browser
      when "github"
        file_md5 = Digest::MD5.hexdigest(file)
        url = "#{base_url}#diff-#{file_md5}"
        if line_number
          url << ((direction == :from) ? "L" : "R")
          url << line_number.to_s
        end
        url
      else
        nil
      end
    end
  end
end
