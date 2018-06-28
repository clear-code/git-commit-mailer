# Copyright (C) 2009  Ryo Onodera <onodera@clear-code.com>
# Copyright (C) 2012-2018  Kouhei Sutou <kou@clear-code.com>
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

# See also post-receive-email in git for git repository
# change detection:
#   http://git.kernel.org/?p=git/git.git;a=blob;f=contrib/hooks/post-receive-email

require "English"
require "optparse"
require "ostruct"
require "time"
require "net/smtp"
require "socket"
require "nkf"
require "shellwords"
require "erb"
require "digest"

require "git-commit-mailer/info"
require "git-commit-mailer/push-info"
require "git-commit-mailer/commit-info"

class SpentTime
  def initialize(label)
    @label = label
    @seconds = 0.0
  end

  def spend
    start_time = Time.now
    returned_object = yield
    @seconds += (Time.now - start_time)
    returned_object
  end

  def report
    puts "#{"%0.9s" % @seconds} seconds spent by #{@label}."
  end
end

class GitCommitMailer
  KILO_SIZE = 1000
  DEFAULT_MAX_SIZE = "100M"

  class << self
    def x_mailer
      "#{name} #{VERSION}; #{URL}"
    end

    def execute(command, working_directory=nil, &block)
      if ENV["DEBUG"]
        suppress_stderr = ""
      else
        suppress_stderr = " 2> /dev/null"
      end

      script = "#{command} #{suppress_stderr}"
      puts script if ENV["DEBUG"]
      result = nil
      with_working_direcotry(working_directory) do
        if block_given?
          IO.popen(script, "w+", &block)
        else
          result = `#{script} 2>&1`
        end
      end
      raise "execute failed: #{command}\n#{result}" unless $?.exitstatus.zero?
      result.force_encoding("UTF-8") if result.respond_to?(:force_encoding)
      result
    end

    def with_working_direcotry(working_directory)
      if working_directory
        Dir.chdir(working_directory) do
          yield
        end
      else
        yield
      end
    end

    def shell_escape(string)
      # To suppress warnings from Shellwords::escape.
      if string.respond_to? :force_encoding
        bytes = string.dup.force_encoding("ascii-8bit")
      else
        bytes = string
      end

      Shellwords.escape(bytes)
    end

    def git(git_bin_path, repository, command, &block)
      $executing_git ||= SpentTime.new("executing git commands")
      $executing_git.spend do
        execute("#{git_bin_path} --git-dir=#{shell_escape(repository)} #{command}", &block)
      end
    end

    def short_revision(revision)
      revision[0, 7]
    end

    def extract_email_address(address)
      if /<(.+?)>/ =~ address
        $1
      else
        address
      end
    end

    def extract_email_address_from_mail(mail)
      begin
        from_header = mail.lines.grep(/\AFrom: .*\Z/)[0]
        extract_email_address(from_header.rstrip.sub(/From: /, ""))
      rescue
        raise '"From:" header is not found in mail.'
      end
    end

    def extract_to_addresses(mail)
      to_value = nil
      if /^To:(.*\r?\n(?:^\s+.*)*)/ni =~ mail
        to_value = $1
      else
        raise "'To:' header is not found in mail:\n#{mail}"
      end
      to_value_without_comment = to_value.gsub(/".*?"/n, "")
      to_value_without_comment.split(/\s*,\s*/n).collect do |address|
        extract_email_address(address.strip)
      end
    end

    def send_mail(server, port, from, to, mail)
      $sending_mail ||= SpentTime.new("sending mails")
      $sending_mail.spend do
        Net::SMTP.start(server, port) do |smtp|
          smtp.open_message_stream(from, to) do |f|
            f.print(mail)
          end
        end
      end
    end

    def parse_options_and_create(argv=nil)
      argv ||= ARGV
      to, options = parse(argv)
      to += options.to
      mailer = new(to.compact)
      apply_options(mailer, options)
      mailer
    end

    def parse(argv)
      options = make_options

      parser = make_parser(options)
      argv = argv.dup
      parser.parse!(argv)
      to = argv

      [to, options]
    end

    def format_size(size)
      return "no limit" if size.nil?
      return "#{size}B" if size < KILO_SIZE
      size /= KILO_SIZE.to_f
      return "#{size}KB" if size < KILO_SIZE
      size /= KILO_SIZE.to_f
      return "#{size}MB" if size < KILO_SIZE
      size /= KILO_SIZE.to_f
      "#{size}GB"
    end

    private
    def apply_options(mailer, options)
      mailer.repository = options.repository
      #mailer.reference = options.reference
      mailer.repository_browser = options.repository_browser
      mailer.github_base_url = options.github_base_url
      mailer.github_user = options.github_user
      mailer.github_repository = options.github_repository
      mailer.gitlab_project_uri = options.gitlab_project_uri
      mailer.send_per_to = options.send_per_to
      mailer.from = options.from
      mailer.from_domain = options.from_domain
      mailer.sender = options.sender
      mailer.add_diff = options.add_diff
      mailer.add_html = options.add_html
      mailer.max_size = options.max_size
      mailer.max_diff_size = options.max_diff_size
      mailer.repository_uri = options.repository_uri
      mailer.rss_path = options.rss_path
      mailer.rss_uri = options.rss_uri
      mailer.show_path = options.show_path
      mailer.send_push_mail = options.send_push_mail
      mailer.name = options.name
      mailer.server = options.server
      mailer.port = options.port
      mailer.date = options.date
      mailer.git_bin_path = options.git_bin_path
      mailer.track_remote = options.track_remote
      mailer.verbose = options.verbose
      mailer.sleep_per_mail = options.sleep_per_mail
    end

    def parse_size(size)
      case size
      when /\A(.+?)GB?\z/i
        Float($1) * KILO_SIZE ** 3
      when /\A(.+?)MB?\z/i
        Float($1) * KILO_SIZE ** 2
      when /\A(.+?)KB?\z/i
        Float($1) * KILO_SIZE
      when /\A(.+?)B?\z/i
        Float($1)
      else
        raise ArgumentError, "invalid size: #{size.inspect}"
      end
    end

    def make_options
      options = OpenStruct.new
      options.repository = ".git"
      #options.reference = "refs/heads/master"
      options.repository_browser = nil
      options.github_base_url = "https://github.com"
      options.github_user = nil
      options.github_repository = nil
      options.gitlab_project_uri = nil
      options.to = []
      options.send_per_to = false
      options.error_to = []
      options.from = nil
      options.from_domain = nil
      options.sender = nil
      options.add_diff = true
      options.add_html = false
      options.max_size = parse_size(DEFAULT_MAX_SIZE)
      options.max_diff_size = parse_size(DEFAULT_MAX_SIZE)
      options.repository_uri = nil
      options.rss_path = nil
      options.rss_uri = nil
      options.show_path = false

      options.send_push_mail = false
      options.name = nil
      options.server = "localhost"
      options.port = Net::SMTP.default_port
      options.date = nil
      options.git_bin_path = "git"
      options.track_remote = false
      options.verbose = false
      options.sleep_per_mail = 0
      options
    end

    def make_parser(options)
      OptionParser.new do |parser|
        parser.banner += " TO"

        add_repository_options(parser, options)
        add_email_options(parser, options)
        add_output_options(parser, options)
        add_rss_options(parser, options)
        add_other_options(parser, options)

        parser.on_tail("--help", "Show this message") do
          puts parser
          exit!
        end
      end
    end

    def add_repository_options(parser, options)
      parser.separator ""
      parser.separator "Repository related options:"

      parser.on("--repository=PATH",
                "Use PATH as the target git repository",
                "(#{options.repository})") do |path|
        options.repository = path
      end

      parser.on("--reference=REFERENCE",
                "Use REFERENCE as the target reference",
                "(#{options.reference})") do |reference|
        options.reference = reference
      end

      available_software = ["github", "github-wiki", "gitlab", "gitlab-wiki"]
      label = available_software.join(", ")
      parser.on("--repository-browser=SOFTWARE",
                available_software,
                "Use SOFTWARE as the repository browser",
                "(available repository browsers: #{label})") do |software|
        options.repository_browser = software
      end

      add_github_options(parser, options)
      add_gitlab_options(parser, options)
    end

    def add_github_options(parser, options)
      parser.separator ""
      parser.separator "GitHub related options:"

      parser.on("--github-base-url=URL",
                "Use URL as base URL of GitHub",
                "(#{options.github_base_url})") do |url|
        options.github_base_url = url
      end

      parser.on("--github-user=USER",
                "Use USER as the GitHub user") do |user|
        options.github_user = user
      end

      parser.on("--github-repository=REPOSITORY",
                "Use REPOSITORY as the GitHub repository") do |repository|
        options.github_repository = repository
      end
    end

    def add_gitlab_options(parser, options)
      parser.separator ""
      parser.separator "GitLab related options:"

      parser.on("--gitlab-project-uri=URI",
                "Use URI as GitLab project URI") do |uri|
        options.gitlab_project_uri = uri
      end
    end

    def add_email_options(parser, options)
      parser.separator ""
      parser.separator "E-mail related options:"

      parser.on("-sSERVER", "--server=SERVER",
                "Use SERVER as SMTP server (#{options.server})") do |server|
        options.server = server
      end

      parser.on("-pPORT", "--port=PORT", Integer,
                "Use PORT as SMTP port (#{options.port})") do |port|
        options.port = port
      end

      parser.on("-tTO", "--to=TO", "Add TO to To: address") do |to|
        options.to << to unless to.nil?
      end

      parser.on("--[no-]send-per-to",
                "Send a mail for each To: address",
                "instead of sending a mail for all To: addresses",
                "(#{options.send_per_to})") do |boolean|
        options.send_per_to = boolean
      end

      parser.on("-eTO", "--error-to=TO",
                "Add TO to To: address when an error occurs") do |to|
        options.error_to << to unless to.nil?
      end

      parser.on("-fFROM", "--from=FROM", "Use FROM as from address") do |from|
        if options.from_domain
          raise OptionParser::CannotCoexistOption,
                  "cannot coexist with --from-domain"
        end
        options.from = from
      end

      parser.on("--from-domain=DOMAIN",
                "Use author@DOMAIN as from address") do |domain|
        if options.from
          raise OptionParser::CannotCoexistOption,
                  "cannot coexist with --from"
        end
        options.from_domain = domain
      end

      parser.on("--sender=SENDER",
                "Use SENDER as a sender address") do |sender|
        options.sender = sender
      end

      parser.on("--sleep-per-mail=SECONDS", Float,
                "Sleep SECONDS seconds after each email sent") do |seconds|
        options.send_per_mail = seconds
      end
    end

    def add_output_options(parser, options)
      parser.separator ""
      parser.separator "Output related options:"

      parser.on("--name=NAME", "Use NAME as repository name") do |name|
        options.name = name
      end

      parser.on("--[no-]show-path",
                "Show commit target path") do |bool|
        options.show_path = bool
      end

      parser.on("--[no-]send-push-mail",
                "Send push mail") do |bool|
        options.send_push_mail = bool
      end

      parser.on("--repository-uri=URI",
                "Use URI as URI of repository") do |uri|
        options.repository_uri = uri
      end

      parser.on("-n", "--no-diff", "Don't add diffs") do |diff|
        options.add_diff = false
      end

      parser.on("--[no-]add-html",
                "Add HTML as alternative content") do |add_html|
        options.add_html = add_html
      end

      parser.on("--max-size=SIZE",
                "Limit mail body size to SIZE",
                "G/GB/M/MB/K/KB/B units are available",
                "(#{format_size(options.max_size)})") do |max_size|
        begin
          options.max_size = parse_size(max_size)
        rescue ArgumentError
          raise OptionParser::InvalidArgument, max_size
        end
      end

      parser.on("--no-limit-size",
                "Don't limit mail body size",
                "(#{options.max_size.nil?})") do |not_limit_size|
        options.max_size = nil
      end

      parser.on("--max-diff-size=SIZE",
                "Limit diff size to SIZE",
                "G/GB/M/MB/K/KB/B units are available",
                "(#{format_size(options.max_diff_size)})") do |max_size|
        begin
          options.max_diff_size = parse_size(max_size)
        rescue ArgumentError
          raise OptionParser::InvalidArgument, max_size
        end
      end

      parser.on("--date=DATE",
                "Use DATE as date of push mails (Time.parse is used)") do |date|
        options.date = Time.parse(date)
      end

      parser.on("--git-bin-path=GIT_BIN_PATH",
                "Use GIT_BIN_PATH command instead of default \"git\"") do |git_bin_path|
        options.git_bin_path = git_bin_path
      end

      parser.on("--track-remote",
                "Fetch new commits from repository's origin and send mails") do
        options.track_remote = true
      end
    end

    def add_rss_options(parser, options)
      parser.separator ""
      parser.separator "RSS related options:"

      parser.on("--rss-path=PATH", "Use PATH as output RSS path") do |path|
        options.rss_path = path
      end

      parser.on("--rss-uri=URI", "Use URI as output RSS URI") do |uri|
        options.rss_uri = uri
      end
    end

    def add_other_options(parser, options)
      parser.separator ""
      parser.separator "Other options:"

      #parser.on("-IPATH", "--include=PATH", "Add PATH to load path") do |path|
      #  $LOAD_PATH.unshift(path)
      #end
      parser.on("--[no-]verbose",
                "Be verbose.",
                "(#{options.verbose})") do |verbose|
        options.verbose = verbose
      end
    end
  end

  attr_reader :reference, :old_revision, :new_revision, :to
  attr_writer :send_per_to
  attr_writer :from, :add_diff, :add_html, :show_path, :send_push_mail
  attr_writer :repository, :date, :git_bin_path, :track_remote
  attr_accessor :from_domain, :sender, :max_size, :max_diff_size, :repository_uri
  attr_accessor :rss_path, :rss_uri, :server, :port
  attr_accessor :repository_browser
  attr_accessor :github_base_url, :github_user, :github_repository
  attr_accessor :gitlab_project_uri
  attr_writer :name, :verbose
  attr_accessor :sleep_per_mail

  def initialize(to)
    @to = to
  end

  def create_push_info(*args)
    PushInfo.new(self, *args)
  end

  def create_commit_info(*args)
    CommitInfo.new(self, *args)
  end

  def git(command, &block)
    GitCommitMailer.git(git_bin_path, @repository, command, &block)
  end

  def get_record(revision, record)
    get_records(revision, [record]).first
  end

  def get_records(revision, records)
    GitCommitMailer.git(git_bin_path, @repository,
                        "log -n 1 --pretty=format:'#{records.join('%n')}%n' " +
                        "#{revision}").lines.collect do |line|
      line.strip
    end
  end

  def send_per_to?
    @send_per_to
  end

  def from(info)
    if @from
      if /\A[^\s<]+@[^\s>]\z/ =~ @from
        @from
      else
        "#{format_name(info.author_name)} <#{@from}>"
      end
    else
      "#{format_name(info.author_name)} <#{info.author_email}>"
    end
  end

  def format_name(name)
    case name
    when /[,"\\]/
      escaped_name = name.gsub(/["\\]/) do |special_character|
        "\\#{special_character}"
      end
      "\"#{escaped_name}\""
    else
      name
    end
  end

  def repository
    @repository || Dir.pwd
  end

  def date
    @date || Time.now
  end

  def git_bin_path
    ENV['GIT_BIN_PATH'] || @git_bin_path
  end

  def track_remote?
    @track_remote
  end

  def verbose?
    @verbose
  end

  def short_new_revision
    GitCommitMailer.short_revision(@new_revision)
  end

  def short_old_revision
    GitCommitMailer.short_revision(@old_revision)
  end

  def origin_references
    references = Hash.new("0" * 40)
    git("rev-parse --symbolic-full-name --tags --remotes").lines.each do |reference|
      reference.rstrip!
      next if reference =~ %r!\Arefs/remotes! and reference !~ %r!\Arefs/remotes/origin!
      references[reference] = git("rev-parse %s" % GitCommitMailer.shell_escape(reference)).rstrip
    end
    references
  end

  def delete_tags
    git("rev-parse --symbolic --tags").lines.each do |reference|
      reference.rstrip!
      git("tag -d %s" % GitCommitMailer.shell_escape(reference))
    end
  end

  def fetch
    updated_references = []
    old_references = origin_references
    delete_tags
    git("fetch --force --tags")
    git("fetch --force")
    new_references = origin_references

    old_references.each do |reference, revision|
      if revision != new_references[reference]
        updated_references << [revision, new_references[reference], reference]
      end
    end
    new_references.each do |reference, revision|
      if revision != old_references[reference]#.sub(/remotes\/origin/, 'heads')
        updated_references << [old_references[reference], revision, reference]
      end
    end
    updated_references.sort do |reference_change1, reference_change2|
      reference_change1.last <=> reference_change2.last
    end.uniq
  end

  def detect_change_type
    if old_revision =~ /0{40}/ and new_revision =~ /0{40}/
      raise "Invalid revision hash"
    elsif old_revision !~ /0{40}/ and new_revision !~ /0{40}/
      :update
    elsif old_revision =~ /0{40}/
      :create
    elsif new_revision =~ /0{40}/
      :delete
    else
      raise "Invalid revision hash"
    end
  end

  def detect_object_type(object_name)
    git("cat-file -t #{object_name}").strip
  end

  def detect_revision_type(change_type)
    case change_type
    when :create, :update
      detect_object_type(new_revision)
    when :delete
      detect_object_type(old_revision)
    end
  end

  def detect_reference_type(revision_type)
    if reference =~ /refs\/tags\/.*/ and revision_type == "commit"
      :unannotated_tag
    elsif reference =~ /refs\/tags\/.*/ and revision_type == "tag"
      # change recipients
      #if [ -n "$announcerecipients" ]; then
      #  recipients="$announcerecipients"
      #fi
      :annotated_tag
    elsif reference =~ /refs\/(heads|remotes\/origin)\/.*/ and revision_type == "commit"
      :branch
    elsif reference =~ /refs\/remotes\/.*/ and revision_type == "commit"
      # tracking branch
      # Push-update of tracking branch.
      # no email generated.
      throw :no_email
    else
      # Anything else (is there anything else?)
      raise "Unknown type of update to #@reference (#{revision_type})"
    end
  end

  def make_push_message(reference_type, change_type)
    unless [:branch, :annotated_tag, :unannotated_tag].include?(reference_type)
      raise "unexpected reference_type"
    end
    unless [:update, :create, :delete].include?(change_type)
      raise "unexpected change_type"
    end

    method_name = "process_#{change_type}_#{reference_type}"
    __send__(method_name)
  end

  def collect_push_information
    change_type = detect_change_type
    revision_type = detect_revision_type(change_type)
    reference_type = detect_reference_type(revision_type)
    messsage, commits = make_push_message(reference_type, change_type)

    [reference_type, change_type, messsage, commits]
  end

  def excluded_revisions
     # refer to the long comment located at the top of this file for the
     # explanation of this command.
     current_reference_revision = git("rev-parse #@reference").strip
     git("rev-parse --not --branches --remotes").lines.find_all do |line|
       line.strip!
       not line.index(current_reference_revision)
     end.collect do |line|
       GitCommitMailer.shell_escape(line)
     end.join(' ')
  end

  def process_create_branch
    message = "Branch (#{@reference}) is created.\n"
    commits = []

    commit_list = []
    git("rev-list #{@new_revision} #{excluded_revisions}").lines.
    reverse_each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      commits << revision
      subject = get_record(revision, '%s')
      commit_list << "     via  #{short_revision} #{subject}\n"
    end
    if commit_list.length > 0
      commit_list[-1].sub!(/\A     via  /, '     at   ')
      message << commit_list.join
    end

    [message, commits]
  end

  def explain_rewind
<<EOF
This update discarded existing revisions and left the branch pointing at
a previous point in the repository history.

 * -- * -- N (#{short_new_revision})
            \\
             O <- O <- O (#{short_old_revision})

The removed revisions are not necessarilly gone - if another reference
still refers to them they will stay in the repository.
EOF
  end

  def explain_rewind_and_new_commits
<<EOF
This update added new revisions after undoing existing revisions.  That is
to say, the old revision is not a strict subset of the new revision.  This
situation occurs when you --force push a change and generate a repository
containing something like this:

 * -- * -- B <- O <- O <- O (#{short_old_revision})
            \\
             N -> N -> N (#{short_new_revision})

When this happens we assume that you've already had alert emails for all
of the O revisions, and so we here report only the revisions in the N
branch from the common base, B.
EOF
  end

  def process_backward_update
    # List all of the revisions that were removed by this update, in a
    # fast forward update, this list will be empty, because rev-list O
    # ^N is empty.  For a non fast forward, O ^N is the list of removed
    # revisions
    fast_forward = false
    revision_found = false
    commits_summary = []
    git("rev-list #{@new_revision}..#{@old_revision}").lines.each do |revision|
      revision_found ||= true
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      subject = get_record(revision, '%s')
      commits_summary << "discards  #{short_revision} #{subject}\n"
    end
    unless revision_found
      fast_forward = true
      subject = get_record(old_revision, '%s')
      commits_summary << "    from  #{short_old_revision} #{subject}\n"
    end
    [fast_forward, commits_summary]
  end

  def process_forward_update
    # List all the revisions from baserev to new_revision in a kind of
    # "table-of-contents"; note this list can include revisions that
    # have already had notification emails and is present to show the
    # full detail of the change from rolling back the old revision to
    # the base revision and then forward to the new revision
    commits_summary = []
    git("rev-list #{@old_revision}..#{@new_revision}").lines.each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)

      subject = get_record(revision, '%s')
      commits_summary << "     via  #{short_revision} #{subject}\n"
    end
    commits_summary
  end

  def explain_special_case
    #  1. Existing revisions were removed.  In this case new_revision
    #     is a subset of old_revision - this is the reverse of a
    #     fast-forward, a rewind
    #  2. New revisions were added on top of an old revision,
    #     this is a rewind and addition.

    # (1) certainly happened, (2) possibly.  When (2) hasn't
    # happened, we set a flag to indicate that no log printout
    # is required.

    # Find the common ancestor of the old and new revisions and
    # compare it with new_revision
    baserev = git("merge-base #{@old_revision} #{@new_revision}").strip
    rewind_only = false
    if baserev == new_revision
      explanation = explain_rewind
      rewind_only = true
    else
      explanation = explain_rewind_and_new_commits
    end
    [rewind_only, explanation]
  end

  def collect_new_commits
    commits = []
    git("rev-list #{@old_revision}..#{@new_revision} #{excluded_revisions}").lines.
    reverse_each do |revision|
      commits << revision.strip
    end
    commits
  end

  def process_update_branch
    message = "Branch (#{@reference}) is updated.\n"

    fast_forward, backward_commits_summary = process_backward_update
    forward_commits_summary = process_forward_update

    commits_summary = backward_commits_summary + forward_commits_summary.reverse

    unless fast_forward
      rewind_only, explanation = explain_special_case
      message << explanation
    end

    message << "\n"
    message << commits_summary.join

    unless rewind_only
      new_commits = collect_new_commits
    end
    if rewind_only or new_commits.empty?
      message << "\n"
      message << "No new revisions were added by this update.\n"
    end

    [message, new_commits]
  end

  def process_delete_branch
    "Branch (#{@reference}) is deleted.\n" +
    "       was  #{@old_revision}\n\n" +
    git("show -s --pretty=oneline #{@old_revision}")
  end

  def process_create_annotated_tag
    "Annotated tag (#{@reference}) is created.\n" +
    "        at  #{@new_revision} (tag)\n" +
    process_annotated_tag
  end

  def process_update_annotated_tag
    "Annotated tag (#{@reference}) is updated.\n" +
    "        to  #{@new_revision} (tag)\n" +
    "      from  #{@old_revision} (which is now obsolete)\n" +
    process_annotated_tag
  end

  def process_delete_annotated_tag
    "Annotated tag (#{@reference}) is deleted.\n" +
    "       was  #{@old_revision}\n\n" +
    git("show -s --pretty=oneline #{@old_revision}").sub(/^Tagger.*$/, '').
                                                     sub(/^Date.*$/, '').
                                                     sub(/\n{2,}/, "\n\n")
  end

  def short_log(revision_specifier)
    log = git("rev-list --pretty=short #{GitCommitMailer.shell_escape(revision_specifier)}")
    git("shortlog") do |git|
      git.write(log)
      git.close_write
      return git.read
    end
  end

  def short_log_from_previous_tag(previous_tag)
    if previous_tag
      # Show changes since the previous release
      short_log("#{previous_tag}..#{@new_revision}")
    else
      # No previous tag, show all the changes since time began
      short_log(@new_revision)
    end
  end

  class NoParentCommit < Exception
  end

  def parent_commit(revision)
    begin
      git("rev-parse #{revision}^").strip
    rescue
      raise NoParentCommit
    end
  end

  def previous_tag_by_revision(revision)
    # If the tagged object is a commit, then we assume this is a
    # release, and so we calculate which tag this tag is
    # replacing
    begin
      git("describe --abbrev=0 #{parent_commit(revision)}").strip
    rescue NoParentCommit
    end
  end

  def annotated_tag_content
    message = ''
    tagger = git("for-each-ref --format='%(taggername)' #{@reference}").strip
    tagged = git("for-each-ref --format='%(taggerdate:rfc2822)' #{@reference}").strip
    message << " tagged by  #{tagger}\n"
    message << "        on  #{format_time(Time.rfc2822(tagged))}\n\n"

    # Show the content of the tag message; this might contain a change
    # log or release notes so is worth displaying.
    tag_content = git("cat-file tag #{@new_revision}").split("\n")
    #skips header section
    tag_content.shift while not tag_content.first.empty?
    #skips the empty line indicating the end of header section
    tag_content.shift

    message << tag_content.join("\n") + "\n"
    message
  end

  def process_annotated_tag
    message = ''
    # Use git for-each-ref to pull out the individual fields from the tag
    tag_object = git("for-each-ref --format='%(*objectname)' #{@reference}").strip
    tag_type = git("for-each-ref --format='%(*objecttype)' #{@reference}").strip

    case tag_type
    when "commit"
      message << "   tagging  #{tag_object} (#{tag_type})\n"
      previous_tag = previous_tag_by_revision(@new_revision)
      message << "  replaces  #{previous_tag}\n" if previous_tag
      message << annotated_tag_content
      message << short_log_from_previous_tag(previous_tag)
    else
      message << "   tagging  #{tag_object} (#{tag_type})\n"
      message << "    length  #{git("cat-file -s #{tag_object}").strip} bytes\n"
      message << annotated_tag_content
    end

    message
  end

  def process_create_unannotated_tag
    raise "unexpected" unless detect_object_type(@new_revision) == "commit"

    "Unannotated tag (#{@reference}) is created.\n" +
    "        at  #{@new_revision} (commit)\n\n" +
    process_unannotated_tag(@new_revision)
  end

  def process_update_unannotated_tag
    raise "unexpected" unless detect_object_type(@new_revision) == "commit"
    raise "unexpected" unless detect_object_type(@old_revision) == "commit"

    "Unannotated tag (#{@reference}) is updated.\n" +
    "        to  #{@new_revision} (commit)\n" +
    "      from  #{@old_revision} (commit)\n\n" +
    process_unannotated_tag(@new_revision)
  end

  def process_delete_unannotated_tag
    raise "unexpected" unless detect_object_type(@old_revision) == "commit"

    "Unannotated tag (#{@reference}) is deleted.\n" +
    "       was  #{@old_revision} (commit)\n\n" +
    process_unannotated_tag(@old_revision)
  end

  def process_unannotated_tag(revision)
    git("show --no-color --root -s --pretty=short #{revision}")
  end

  def find_branch_name_from_its_descendant_revision(revision)
    begin
      name = git("name-rev --name-only --refs refs/heads/* #{revision}").strip
      revision = parent_commit(revision)
    end until name.sub(/([~^][0-9]+)*\z/, '') == name
    name
  end

  def traverse_merge_commit(merge_commit)
    first_grand_parent = parent_commit(merge_commit.first_parent)

    [merge_commit.first_parent, *merge_commit.other_parents].each do |revision|
      is_traversing_first_parent = (revision == merge_commit.first_parent)
      base_revision = git("merge-base #{first_grand_parent} #{revision}").strip
      base_revisions = [@old_revision, base_revision]
      #branch_name = find_branch_name_from_its_descendant_revision(revision)
      descendant_revision = merge_commit.revision

      until base_revisions.index(revision)
        commit_info = @commit_info_map[revision]
        if commit_info
          commit_info.reference = @reference
        else
          commit_info = create_commit_info(@reference, revision)
          index = @commit_infos.index(@commit_info_map[descendant_revision])
          @commit_infos.insert(index, commit_info)
          @commit_info_map[revision] = commit_info
        end

        merge_message = "Merged #{merge_commit.short_revision}: #{merge_commit.subject}"
        if not is_traversing_first_parent and not commit_info.merge_messages.index(merge_message)
          commit_info.merge_messages << merge_message
          commit_info.merge_commits << merge_commit
        end

        if commit_info.merge?
          traverse_merge_commit(commit_info)
          base_revision = git("merge-base #{first_grand_parent} #{commit_info.first_parent}").strip
          base_revisions << base_revision unless base_revisions.index(base_revision)
        end
        descendant_revision, revision = revision, commit_info.first_parent
      end
    end
  end

  def post_process_infos
    # @push_info.author_name = determine_prominent_author
    commit_infos = @commit_infos.dup
    # @commit_infos may be altered and I don't know any sensible behavior of ruby
    # in such cases. Take the safety measure at the moment...
    commit_infos.reverse_each do |commit_info|
      traverse_merge_commit(commit_info) if commit_info.merge?
    end
  end

  def determine_prominent_author
    #if @commit_infos.length > 0
    #
    #else
    #   @push_info
  end

  def reset(old_revision, new_revision, reference)
    @old_revision = old_revision
    @new_revision = new_revision
    @reference = reference

    @push_info = nil
    @commit_infos = []
    @commit_info_map = {}
  end

  def make_infos
    catch(:no_email) do
      @push_info = create_push_info(old_revision, new_revision, reference,
                                    *collect_push_information)
      if @push_info.branch_changed?
        @push_info.commits.each do |revision|
          commit_info = create_commit_info(reference, revision)
          @commit_infos << commit_info
          @commit_info_map[revision] = commit_info
        end
      end
    end

    post_process_infos
  end

  def make_mails
    if send_per_to?
      @push_mails = @to.collect do |to|
        make_mail(@push_info, [to])
      end
    else
      @push_mails = [make_mail(@push_info, @to)]
    end

    @commit_mails = []
    @commit_infos.each do |info|
      if send_per_to?
        @to.each do |to|
          @commit_mails << make_mail(info, [to])
        end
      else
        @commit_mails << make_mail(info, @to)
      end
    end
  end

  def process_reference_change(old_revision, new_revision, reference)
    reset(old_revision, new_revision, reference)

    make_infos
    make_mails
    if rss_output_available?
      output_rss
    end

    [@push_mails, @commit_mails]
  end

  def send_all_mails
    if send_push_mail?
      @push_mails.each do |mail|
        send_mail(mail)
      end
    end

    @commit_mails.each do |mail|
      send_mail(mail)
    end
  end

  def add_diff?
    @add_diff
  end

  def add_html?
    @add_html
  end

  def show_path?
    @show_path
  end

  def send_push_mail?
    @send_push_mail
  end

  def format_time(time)
    time.strftime('%Y-%m-%d %X %z (%a, %d %b %Y)')
  end

  private
  def send_mail(mail)
    server = @server || "localhost"
    port = @port
    from = sender || GitCommitMailer.extract_email_address_from_mail(mail)
    to = GitCommitMailer.extract_to_addresses(mail)
    GitCommitMailer.send_mail(server, port, from, to, mail)
    sleep(@sleep_per_mail)
  end

  def output_rss
    prev_rss = nil
    begin
      if File.exist?(@rss_path)
        File.open(@rss_path) do |f|
          prev_rss = RSS::Parser.parse(f)
        end
      end
    rescue RSS::Error
    end

    rss = make_rss(prev_rss).to_s
    File.open(@rss_path, "w") do |f|
      f.print(rss)
    end
  end

  def rss_output_available?
    if @repository_uri and @rss_path and @rss_uri
      begin
        require 'rss'
        true
      rescue LoadError
        false
      end
    else
      false
    end
  end

  def make_mail(info, to)
    @boundary = generate_boundary

    multipart_body_p = false
    body_text = info.format_mail_body_text
    body_html = nil
    if add_html?
      body_html = info.format_mail_body_html
      multipart_body_p = (body_text.size + body_html.size) < @max_size
    end
    unless multipart_body_p
      body_text = truncate_body(body_text, @max_size)
    end

    encoding = "utf-8"
    if need_base64_encode?(body_text) or need_base64_encode?(body_html)
      transfer_encoding = "base64"
      body_text = [body_text].pack("m")
      if body_html
        body_html = [body_html].pack("m")
      end
    else
      transfer_encoding = "8bit"
    end

    if multipart_body_p
      body = <<-EOB
--#{@boundary}
Content-Type: text/plain; charset=#{encoding}
Content-Transfer-Encoding: #{transfer_encoding}

#{body_text}
--#{@boundary}
Content-Type: text/html; charset=#{encoding}
Content-Transfer-Encoding: #{transfer_encoding}

#{body_html}
--#{@boundary}--
EOB
    else
      body = body_text
    end

    header = make_header(encoding, transfer_encoding, to, info, multipart_body_p)
    if header.respond_to?(:force_encoding)
      header.force_encoding("BINARY")
      body.force_encoding("BINARY")
    end
    header + "\n" + body
  end

  def need_base64_encode?(text)
    return false if text.nil?
    text.lines.any? {|line| line.bytesize >= 998}
  end

  def name
    return @name if @name
    repository = File.expand_path(@repository)
    loop do
      basename = File.basename(repository, ".git")
      if basename != ".git"
        return basename
      else
        repository = File.dirname(repository)
      end
    end
  end

  def make_header(body_encoding,
                  body_transfer_encoding,
                  to,
                  info,
                  multipart_body_p)
    subject = ""
    subject << "#{name}@" if name
    subject << "#{info.short_revision} "
    subject << mime_encoded_word("#{info.format_mail_subject}")
    headers = []
    headers += info.headers
    headers << "X-Mailer: #{self.class.x_mailer}"
    headers << "MIME-Version: 1.0"
    if multipart_body_p
      headers << "Content-Type: multipart/alternative;"
      headers << " boundary=#{@boundary}"
    else
      headers << "Content-Type: text/plain; charset=#{body_encoding}"
      headers << "Content-Transfer-Encoding: #{body_transfer_encoding}"
    end
    headers << "From: #{from(info)}"
    headers << "To: #{to.join(', ')}"
    headers << "Subject: #{subject}"
    headers << "Date: #{info.date.rfc2822}"
    headers << "Sender: #{sender}" if sender
    headers.find_all do |header|
      /\A\s*\z/ !~ header
    end.join("\n") + "\n"
  end

  def generate_boundary
    random_integer = Time.now.to_i * 1000 + rand(1000)
    Digest::SHA1.hexdigest(random_integer.to_s)
  end

  def detect_project
    project = File.open("#{repository}/description").gets.strip
    # Check if the description is unchanged from it's default, and shorten it to
    # a more manageable length if it is
    if project =~ /Unnamed repository.*$/
      project = nil
    end

    project
  end

  def mime_encoded_word(string)
    #XXX "-MWw" didn't work in some versions of Ruby 1.9.
    #    giving up to stick with UTF-8... ;)
    encoded_string = NKF.nkf("-MWj", string)

    #XXX The actual MIME encoded-word's string representaion is US-ASCII,
    #    which, in turn, can be UTF-8. In spite of this fact, in some versions
    #    of Ruby 1.9, encoded_string.encoding is incorrectly set as ISO-2022-JP.
    #    Fortunately, as we just said, we can just safely override them with
    #    "UTF-8" to work around this bug.
    if encoded_string.respond_to?(:force_encoding)
      encoded_string.force_encoding("UTF-8")
    end

    #XXX work around NKF's bug of gratuitously wrapping long ascii words with
    #    MIME encoded-word syntax's header and footer, while not actually
    #    encoding the payload as base64: just strip the header and footer out.
    encoded_string.gsub!(/\=\?EUC-JP\?B\?(.*)\?=\n /) {$1}
    encoded_string.gsub!(/(\n )*=\?US-ASCII\?Q\?(.*)\?=(\n )*/) {$2}

    encoded_string
  end

  def truncate_body(body, max_size)
    return body if max_size.nil?
    return body if body.size < max_size

    truncated_body = body[0, max_size]
    formatted_size = self.class.format_size(max_size)
    truncated_message = "... truncated to #{formatted_size}\n"
    truncated_message_size = truncated_message.size

    lf_index = truncated_body.rindex(/(?:\r|\r\n|\n)/)
    while lf_index
      if lf_index + truncated_message_size < max_size
        truncated_body[lf_index, max_size] = "\n#{truncated_message}"
        break
      else
        lf_index = truncated_body.rindex(/(?:\r|\r\n|\n)/, lf_index - 1)
      end
    end

    truncated_body
  end

  def make_rss(base_rss)
    RSS::Maker.make("1.0") do |maker|
      maker.encoding = "UTF-8"

      maker.channel.about = @rss_uri
      maker.channel.title = rss_title(name || @repository_uri)
      maker.channel.link = @repository_uri
      maker.channel.description = rss_title(@name || @repository_uri)
      maker.channel.dc_date = @push_info.date

      if base_rss
        base_rss.items.each do |item|
          item.setup_maker(maker)
        end
      end

      @commit_infos.each do |info|
        item = maker.items.new_item
        item.title = info.rss_title
        item.description = info.summary
        item.content_encoded = info.rss_content
        item.link = "#{@repository_uri}/commit/?id=#{info.revision}"
        item.dc_date = info.date
        item.dc_creator = info.author_name
      end

      maker.items.do_sort = true
      maker.items.max_size = 15
    end
  end

  def rss_title(name)
    "Repository of #{name}"
  end
end

require "git-commit-mailer/version"
