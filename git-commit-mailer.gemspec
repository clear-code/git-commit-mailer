# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'git-commit-mailer/version'

Gem::Specification.new do |spec|
  spec.name          = "git-commit-mailer"
  spec.version       = GitCommitMailer::VERSION
  spec.authors       = ["Ryo Onodera", "Kouhei Sutou", "Kenji Okimoto"]
  spec.email         = ["onodera@clear-code.com", "kou@clear-code.com", "okimoto@clear-code.com"]

  spec.summary       = %q{A utility to send commit mails for commits pushed to git repositories.}
  spec.description   = %q{A utility to send commit mails for commits pushed to git repositories.}
  spec.homepage      = "https://github.com/clear-code/git-commit-mailer"
  spec.license       = "GPL-3.0+"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "bin"
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "test-unit"
  spec.add_development_dependency "test-unit-rr"
end
