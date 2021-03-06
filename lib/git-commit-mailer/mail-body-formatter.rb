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

    parameters = ERB.instance_method(:initialize).parameters
    if parameters.include?([:key, :trim_mode])
      def format
        ERB.new(template, trim_mode: "<>").result(binding)
      end
    else
      def format
        ERB.new(template, nil, "<>").result(binding)
      end
    end

    private
    def commit_url
      case @mailer.repository_browser
      when "github"
        revision = @info.revision
        commit_url_github(revision)
      when "github-wiki"
        file = (@info.updated_files + @info.added_files).first
        commit_file_url_github_wiki(file)
      when "gitlab"
        return nil if @mailer.gitlab_project_uri.nil?
        revision = @info.revision
        "#{@mailer.gitlab_project_uri}/commit/#{revision}"
      when "gitlab-wiki"
        file = (@info.updated_files + @info.added_files).first
        commit_file_url_gitlab_wiki(file)
      else
        nil
      end
    end

    def commit_url_github(revision)
      user = @mailer.github_user
      repository = @mailer.github_repository
      return nil if user.nil? or repository.nil?

      base_url = @mailer.github_base_url
      "#{base_url}/#{user}/#{repository}/commit/#{revision}"
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

    def commit_file_url_gitlab_wiki(file)
      return nil if file.nil?

      gitlab_project_uri = @mailer.gitlab_project_uri
      return nil if gitlab_project_uri.nil?

      page_name = file.gsub(/\.[^.]+\z/, "")
      page_name_in_url = ERB::Util.u(page_name)
      revision = @info.revision
      "#{gitlab_project_uri}/wikis/#{page_name_in_url}?version_id=#{revision}"
    end
  end
end
