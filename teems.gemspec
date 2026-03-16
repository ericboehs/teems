# frozen_string_literal: true

require_relative 'lib/teems/version'

Gem::Specification.new do |spec|
  spec.name = 'teems'
  spec.version = Teems::VERSION
  spec.authors = ['Eric Boehs']
  spec.email = ['ericboehs@gmail.com']

  spec.summary = 'A command-line interface for Microsoft Teams'
  spec.description = 'Read messages, list channels and chats from Microsoft Teams ' \
                     'in the terminal. Pure Ruby, no dependencies.'
  spec.homepage = 'https://github.com/ericboehs/teems'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/ericboehs/teems'
  spec.metadata['changelog_uri'] = 'https://github.com/ericboehs/teems/blob/master/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem
  spec.files = Dir.chdir(__dir__) do
    Dir['{bin,lib,support,docs}/**/*', 'LICENSE', 'README.md', 'CHANGELOG.md'].reject do |f|
      File.directory?(f) || f.end_with?('.bash')
    end
  end

  spec.bindir = 'bin'
  spec.executables = ['teems']
  spec.require_paths = ['lib']

  # No runtime dependencies - pure Ruby!
end
