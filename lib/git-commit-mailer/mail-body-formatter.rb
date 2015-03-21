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
end
