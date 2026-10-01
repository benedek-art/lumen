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
  # A re-run of an old main run passes every gate with an old commit. The publisher
  # must ask where main is now, refuse unless it is this run's commit, and do so
  # unconditionally and BEFORE anything is published.
  steps = Array(publisher['steps'])
  tip_check = steps.index do |s|
    run = s['run'].to_s
    run.include?('ls-remote origin refs/heads/main') && run.include?('"$TIP" != "$GITHUB_SHA"') &&
      run.include?('exit 1') && !run.match?(/\|\|\s*true|\bexit 0\b/)
  end
  publish_step = steps.index { |s| s['run'].to_s.include?('gh release create') }
  unless tip_check && publish_step && tip_check < publish_step &&
         !steps[tip_check].key?('if') && !steps[tip_check]['continue-on-error']
    errors << 'publisher must refuse a run that is not the current tip of main'
  end
  required.each do |name|
    job = jobs[name]
    if !job
      errors << "missing required job #{name}"
      next
    end
    errors << "#{name} cannot ignore failures" if job['continue-on-error'] || Array(job['steps']).any? { |s| s['continue-on-error'] }
    # A lane that does not run, or whose verdict is replaced, is green without testing.
    # Only release-validation's own branch condition is allowed at job level, and only
    # the cached toolchain install may be conditional at step level.
    allowed_job_if = name == 'release-validation' ? "github.ref == 'refs/heads/main'" : nil
    errors << "#{name} must not be conditional" unless job['if'] == allowed_job_if
    Array(job['steps']).each do |step|
      run = step['run'].to_s
      if step.key?('if') && !run.include?('install-linux-toolchain.sh')
        errors << "#{name} must not skip a verification step"
      end
      # `| tee` reports tee's status unless pipefail is on. GitHub turns pipefail on
      # only for an EXPLICIT `shell: bash`; the implicit default is `bash -e {0}`.
      if run.include?('| tee') && (step['shell'] != 'bash' || run.include?('+o pipefail'))
        errors << "#{name} must keep pipefail on a piped verification step"
      end
      if run.include?('status=$?') && run.lines.map(&:strip).reject(&:empty?).last != 'exit $status'
        errors << "#{name} must exit with the captured verification status"
      end
      errors << "#{name} must not discard a failing status" if run.match?(/\|\|\s*true|\bexit 0\b/)
    end
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
  ->(w) { w['jobs']['app-bundle']['steps'] << { 'run' => 'gh release create dev-latest' } },
  ->(w) { w['jobs']['test-fast']['steps'].last['if'] = 'false' },
  ->(w) { w['jobs']['release-validation']['steps'].last['if'] = 'false' },
  ->(w) { w['jobs']['engine-linux']['if'] = "github.ref != 'refs/heads/main'" },
  ->(w) { w['jobs']['test-fast']['steps'].last.delete('shell') },
  ->(w) { s = w['jobs']['test-fast']['steps'].last; s['run'] = "set +o pipefail\n" + s['run'] },
  ->(w) { s = w['jobs']['engine-linux']['steps'].last; s['run'] = s['run'].sub('exit $status', 'exit 0') },
  ->(w) { s = w['jobs']['test-fast']['steps'].last; s['run'] = s['run'].sub('exit $status', 'echo done') },
  ->(w) { s = w['jobs']['fixtures-linux']['steps'].find { |x| x['run'].to_s.include?('gen-fixtures') }; s['run'] += ' || true' },
  # The tip-of-main refusal: removed, moved after the publication, skipped, made
  # non-fatal, or inverted.
  ->(w) { w['jobs']['publish-release']['steps'].reject! { |x| x['run'].to_s.include?('ls-remote') } },
  ->(w) { s = w['jobs']['publish-release']['steps']; g = s.index { |x| x['run'].to_s.include?('ls-remote') }; s << s.delete_at(g) },
  ->(w) { w['jobs']['publish-release']['steps'].find { |x| x['run'].to_s.include?('ls-remote') }['if'] = 'false' },
  ->(w) { w['jobs']['publish-release']['steps'].find { |x| x['run'].to_s.include?('ls-remote') }['continue-on-error'] = true },
  ->(w) { s = w['jobs']['publish-release']['steps'].find { |x| x['run'].to_s.include?('ls-remote') }; s['run'] = s['run'].sub('exit 1', 'exit 0') },
  ->(w) { s = w['jobs']['publish-release']['steps'].find { |x| x['run'].to_s.include?('ls-remote') }; s['run'] = s['run'].sub('!=', '=') }
]
mutations.each_with_index do |mutate, index|
  changed = Marshal.load(Marshal.dump(workflow))
  mutate.call(changed)
  abort "Unsafe mutation #{index + 1} passed" if violations(changed).empty?
end
puts "Release policy passed; #{mutations.length} unsafe mutations rejected."
