[![Build Status](https://travis-ci.org/clear-code/git-commit-mailer.svg?branch=master)](https://travis-ci.org/clear-code/git-commit-mailer)

This project has been moved to https://gitlab.com/clear-code/git-commit-mailer .

# GitCommitMailer

A utility to send commit mails for commits pushed to Git repositories.

See also [Git](http://git-scm.com/).

## Authors

* Kouhei Sutou <kou@clear-code.com>
* Ryo Onodera <onodera@clear-code.com>
* Kenji Okimoto <okimoto@clear-code.com>

## License

GitCommitMailer is licensed under GPLv3 or later. See
doc/text/GPL-3.txt for details.

## Dependencies

* Ruby >= 1.9.3
* Git >= 1.7

## Install

~~~
$ gem install git-commit-mailer
~~~

git-commit-mailer utilizes Git's hook functionality to send
commit mails.

Edit "post-receive" shell script file to execute it from there,
which is located under "hooks" directory in a Git repository.

Example:

~~~
git-commit-mailer \
  --from-domain=example.com \
  --error-to=onodera@example.com \
  commit@example.com
~~~

For more detailed usage and options, execute git-commit-mailer
with `--help` option.
