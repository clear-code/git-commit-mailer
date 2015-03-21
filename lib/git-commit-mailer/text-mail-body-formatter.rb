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
  class CommitInfo
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
  end
end
