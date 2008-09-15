Gem::Specification.new do |s|
  s.name = "acts-as-taggable-on"
  s.version = "1.0.2"
  s.date = "2008-06-10"
  s.summary = "Tagging for ActiveRecord with custom contexts and advanced features."
  s.email = "michael@intridea.com"
  s.homepage = "http://www.actsascommunity.com/projects/acts-as-taggable-on"
  s.description = "Acts As Taggable On provides the ability to have multiple tag contexts on a single model in ActiveRecord. It also has support for tag clouds, related items, taggers, and more."
  s.has_rdoc = false
  s.authors = ["Michael Bleigh", 'Mathieu Fosse', 'David Masover']
  s.files = [ "CHANGELOG",
              "MIT-LICENSE",
              "README" ] + Dir.glob('**/*.rb')
  #s.rdoc_options = ["--main", "README.txt"]
  #s.extra_rdoc_files = ["History.txt", "Manifest.txt", "README.txt"]
  #s.add_dependency("mbleigh-mash", [">= 0.0.5"])
end