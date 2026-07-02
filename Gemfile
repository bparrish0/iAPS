source "https://rubygems.org"

# Pinned to the last dev commit before the 2026-06-27 upstream merge: fastlane/fastlane#30061
# makes altool uploads pass "-assetFile", a flag altool doesn't support, which breaks the
# TestFlight upload with "Expected file path argument is missing, --file. (21)". Unpin once
# fastlane restores the altool "-f" handling.
gem "fastlane", git: "https://github.com/Artificial-Pancreas/fastlane.git", ref: "70223d34a56e11449e8865315fc4260b98110c80"
gem "abbrev", git: "https://github.com/ruby/abbrev.git", branch: "master"
