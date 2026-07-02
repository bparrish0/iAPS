source "https://rubygems.org"

# Pinned so CI builds are reproducible (no Gemfile.lock is committed and CI runs
# `bundle update fastlane`, so an unpinned branch drifts under us). This revision needs the
# altool "-f" monkey-patch at the top of fastlane/Fastfile — see the comment there. Older
# revisions aren't an option: they require kconv, removed from Ruby 3.4 default gems, and the
# CI runner now ships Ruby 3.4.
gem "fastlane", git: "https://github.com/Artificial-Pancreas/fastlane.git", ref: "6682560014760512e1efd3a81032d390ae2a43fb"
gem "abbrev", git: "https://github.com/ruby/abbrev.git", branch: "master"
