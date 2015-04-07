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
  class PushInfo < Info
    attr_reader :old_revision, :new_revision, :reference, :reference_type, :log
    attr_reader :author_name, :author_email, :date, :subject, :change_type
    attr_reader :commits
    def initialize(mailer, old_revision, new_revision, reference,
                   reference_type, change_type, log, commits=[])
      @mailer = mailer
      @old_revision = old_revision
      @new_revision = new_revision
      if @new_revision != '0' * 40 #XXX well, i need to properly fix this bug later.
        @revision = @new_revision
      else
        @revision = @old_revision
      end
      @reference = reference
      @reference_type = reference_type
      @log = log
      author_name, author_email = get_records(["%an", "%ae"])
      @author_name = author_name
      @author_email = author_email
      @date = @mailer.date
      @change_type = change_type
      @commits = commits || []
    end

    def revision
      @new_revision
    end

    def message_id
      "<push.#{old_revision}.#{new_revision}@#{self.class.host_name}>"
    end

    def headers
      [
        "X-Git-OldRev: #{old_revision}",
        "X-Git-NewRev: #{new_revision}",
        "X-Git-Refname: #{reference}",
        "X-Git-Reftype: #{REFERENCE_TYPE[reference_type]}",
        "Message-ID: #{message_id}",
      ]
    end

    def branch_changed?
      !@commits.empty?
    end

    REFERENCE_TYPE = {
      :branch => "branch",
      :annotated_tag => "annotated tag",
      :unannotated_tag => "unannotated tag"
    }
    CHANGE_TYPE = {
      :create => "created",
      :update => "updated",
      :delete => "deleted",
    }

    def format_mail_subject
      "(push) #{PushInfo::REFERENCE_TYPE[reference_type]} " +
        "(#{short_reference}) is #{PushInfo::CHANGE_TYPE[change_type]}."
    end

    def format_mail_body_text
      body = ""
      body << "#{author_name}\t#{@mailer.format_time(date)}\n"
      body << "\n"
      body << "New Push:\n"
      body << "\n"
      body << "  Message:\n"
      log.rstrip.each_line do |line|
        body << "    #{line}"
      end
      body << "\n\n"
    end

    def format_mail_body_html
      "<pre>#{ERB::Util.h(format_mail_body_text)}</pre>"
    end
  end
end
