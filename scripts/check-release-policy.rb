#!/usr/bin/env ruby
# Offline policy check, not a simulation of a GitHub-hosted run.
require 'yaml'

def violations(workflow)
  jobs = workflow.fetch('jobs')
  errors = []
  errors << 'default workflow access must be read-only' unless workflow.dig('permissions', 'contents') == 'read'
  publisher = jobs['publish-release']
  return ['release publication must be a separate gated job'] unless publisher
  required = %w[app-bundle build-macos test-fast fixtures-linux engine-linux release-validation]
  errors << 'publisher must depend on every required check' unless Array(publisher['needs']).sort == required.sort
  errors << 'only successful main runs may publish' unless publisher['if'] == "success() && github.ref == 'refs/heads/main'"
  errors << 'publisher cannot continue after failure' if publisher['continue-on-error']
  required.each do |name|
    job = jobs[name]
    if !job
      errors << "missing required job #{name}"
      next
    end
    errors << "#{name} cannot ignore failures" if job['continue-on-error'] || Array(job['steps']).any? { |s| s['continue-on-error'] }
  end
  validation = jobs['release-validation'] || {}
  runs = Array(validation['steps']).map { |step| step['run'].to_s }
  errors << 'release validation must run the unfiltered optimized suite' unless runs.include?('swift test -c release')
  jobs.each do |name, job|
    next if name == 'publish-release'
    errors << "#{name} must not have contents write access" if job.dig('permissions', 'contents') == 'write'
    Array(job['steps']).each do |step|
      errors << "#{name} must not publish" if step['run'].to_s.match?(/gh release|git push.*dev-latest/)
    end
  end
  errors
end

workflow = YAML.load_file(File.expand_path('../.github/workflows/ci.yml', __dir__))
errors = violations(workflow)
unless errors.empty?
  warn errors.join("\n")
  exit 1
end

# Guard the guard: each unsafe mutation must be rejected by the actual policy.
mutations = [
  ->(w) { w['permissions']['contents'] = 'write' },
  ->(w) { w['jobs']['publish-release'].delete('needs') },
  ->(w) { w['jobs']['publish-release']['if'] = 'always()' },
  ->(w) { w['jobs']['publish-release']['if'] = "success() && github.ref == 'refs/heads/claude/photo-editor-design-plan-8ahzmm'" },
  ->(w) { w['jobs']['test-fast']['continue-on-error'] = true },
  ->(w) { w['jobs']['release-validation']['steps'].last['run'] = 'swift test --skip LumenPipelineTests' },
  ->(w) { w['jobs']['app-bundle']['permissions'] = { 'contents' => 'write' } },
  ->(w) { w['jobs']['app-bundle']['steps'] << { 'run' => 'gh release create dev-latest' } }
]
mutations.each_with_index do |mutate, index|
  changed = Marshal.load(Marshal.dump(workflow))
  mutate.call(changed)
  abort "Unsafe mutation #{index + 1} passed" if violations(changed).empty?
end
puts "Release policy passed; #{mutations.length} unsafe mutations rejected."
