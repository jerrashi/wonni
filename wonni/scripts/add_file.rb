require 'xcodeproj'

project_path = '/Users/jerryshi/Documents/GitHub/wonni/wonni/wonni.xcodeproj'
project = Xcodeproj::Project.open(project_path)

group = project.main_group.find_subpath(File.join('wonni', 'Views'), true)
target = project.targets.first

file_path = '/Users/jerryshi/Documents/GitHub/wonni/wonni/wonni/Views/PhotoEditModal.swift'
file_ref = group.new_reference(file_path)

target.add_file_references([file_ref])
project.save
