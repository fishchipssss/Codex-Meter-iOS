#!/usr/bin/env ruby

require "fileutils"
require "pathname"
require "xcodeproj"

project_path, marketing_version, build_number = ARGV
abort "usage: prepare_codemagic_project.rb PROJECT VERSION BUILD" unless project_path && marketing_version && build_number

project_path = File.expand_path(project_path)
repository_root = File.expand_path("..", __dir__)
asset_catalog = File.join(repository_root, "Resources", "Assets.xcassets")
app_icon = File.join(repository_root, "Resources", "AppIcon.png")
catalog_icon = File.join(asset_catalog, "AppIcon.appiconset", "AppIcon.png")
dark_icon = File.join(asset_catalog, "AppIcon.appiconset", "AppIcon-Dark.png")
tinted_icon = File.join(asset_catalog, "AppIcon.appiconset", "AppIcon-Tinted.png")

abort "missing generated Xcode project: #{project_path}" unless File.directory?(project_path)
abort "missing app icon: #{app_icon}" unless File.file?(app_icon)
abort "missing dark app icon: #{dark_icon}" unless File.file?(dark_icon)
abort "missing tinted app icon: #{tinted_icon}" unless File.file?(tinted_icon)

FileUtils.cp(app_icon, catalog_icon)

project = Xcodeproj::Project.open(project_path)
app_target = project.targets.find { |target| target.product_type == "com.apple.product-type.application" }
abort "generated project has no application target" unless app_target

asset_group = project.main_group.find_subpath("Codex Meter Assets", true)
asset_reference = asset_group.files.find { |file| file.path == asset_catalog }
asset_reference ||= asset_group.new_file(asset_catalog)

unless app_target.resources_build_phase.files_references.include?(asset_reference)
  app_target.resources_build_phase.add_file_reference(asset_reference)
end

project.targets.each do |target|
  target.build_configurations.each do |configuration|
    configuration.build_settings["MARKETING_VERSION"] = marketing_version
    configuration.build_settings["CURRENT_PROJECT_VERSION"] = build_number
    configuration.build_settings["INFOPLIST_KEY_CFBundleShortVersionString"] = marketing_version
    configuration.build_settings["INFOPLIST_KEY_CFBundleVersion"] = build_number
  end
end

# xtool gives every generated target a concrete Info.plist. Xcode does not
# apply INFOPLIST_KEY_CFBundleVersion to those files consistently, so write
# the archive versions into the exact plists the targets will process.
bundle_targets = project.targets.select do |target|
  ["com.apple.product-type.application", "com.apple.product-type.app-extension"].include?(target.product_type)
end

versioned_plists = bundle_targets.flat_map do |target|
  target.build_configurations.filter_map do |configuration|
    setting = configuration.resolve_build_setting("INFOPLIST_FILE", target)
    next if setting.nil? || setting.empty?

    expanded = setting
      .gsub("$(SRCROOT)", project.project_dir.to_s)
      .gsub("${SRCROOT}", project.project_dir.to_s)
      .gsub("$(PROJECT_DIR)", project.project_dir.to_s)
      .gsub("${PROJECT_DIR}", project.project_dir.to_s)
    path = Pathname.new(expanded)
    path = project.project_dir + path unless path.absolute?
    [target.name, path.cleanpath]
  end
end.uniq

abort "generated targets have no Info.plist build setting" if versioned_plists.empty?

versioned_plists.each do |target_name, plist_path|
  abort "missing generated Info.plist for #{target_name}: #{plist_path}" unless plist_path.file?
  plist = Xcodeproj::Plist.read_from_path(plist_path)
  plist["CFBundleShortVersionString"] = marketing_version
  plist["CFBundleVersion"] = build_number
  Xcodeproj::Plist.write_to_path(plist, plist_path)
  puts "Versioned #{target_name} Info.plist at #{plist_path}"
end

app_target.build_configurations.each do |configuration|
  configuration.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
end

project.save

puts "Prepared #{app_target.name} #{marketing_version} (#{build_number}) with AppIcon"
