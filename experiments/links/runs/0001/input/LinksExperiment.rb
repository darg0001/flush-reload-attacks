#!/usr/bin/env ruby

require 'digest'
require 'yaml'

if ARGV[0].nil?
  puts "Must pass output directory on command line!"
  exit(false)
end

URL_LIST_FILE = "url_sets/small-test.txt"
SAMPLE_COUNT = 3
OUTPUT_DIR = ARGV[0]
LINKS_PATH = "binaries/links"
VICTIM_RUNS = 3

results = {
  "url_list_file" => URL_LIST_FILE,
  "sample_count" => 1,
  "links_path" => LINKS_PATH,
  "victim_runs" => VICTIM_RUNS,
  "training_time" => nil,
  "urls" => {}
}

# Training
# ---------------------------------------

train_dir = File.join(OUTPUT_DIR, "training")
start_time = Time.now
train_pid = Process.spawn(
  *[
    "ruby",
    "AttackTrainer.rb",
    "--url-list", URL_LIST_FILE,
    "--train-dir", train_dir,
    "--links-path", LINKS_PATH,
    "--samples", SAMPLE_COUNT.to_s
  ]
)
Process.wait(train_pid)
end_time = Time.now
results["training_time"] = (end_time - start_time)

# Spying
# ---------------------------------------

urls = File.readlines(URL_LIST_FILE).map { |line| line.chomp }

recordings_dir = File.join(OUTPUT_DIR, "recordings")
Dir.mkdir(recordings_dir)

urls.each do |victim_url|
  print victim_url + ": "
  url_hash = Digest::SHA256.hexdigest(victim_url)

  results["urls"][victim_url] = Array.new(VICTIM_RUNS)
  VICTIM_RUNS.times do |run|
    results["urls"][victim_url][run] = {
      "status" => nil,
      "recovery_time" => nil,
    }
    record_dir = File.join(recordings_dir, url_hash + "_" + run.to_s)

    recording_pid = Process.spawn(
      *[
        "ruby",
        "AttackRecorder.rb",
        "--links-path", LINKS_PATH,
        "--output-dir", record_dir
      ]
    )

    # Wait for the recorder to get going.
    sleep 1

    links = IO.popen([ LINKS_PATH, victim_url, :err=>[:child, :out]])

    # Wait for links to load the page, then kill it.
    sleep 3
    # Use SIGINT. SIGKILL leaves the terminal broken.
    Process.kill("INT", links.pid)
    # Wait for the bursting algorithm to finish the burst.
    sleep 3
    # Kill the recorder.
    Process.kill("KILL", recording_pid)

    record_files = Dir.entries(record_dir) - [".", ".."]

    if record_files.length != 1
      results["urls"][victim_url][run]["status"] = "fail_recording"
      print "R "
      next
    end

    start_time = Time.now
    recovery = IO.popen(
      [
        "ruby",
        "AttackRecovery.rb",
        "--recording-dir", record_dir,
        "--train-dir", train_dir
      ]
    )
    Process.wait(recovery.pid)
    end_time = Time.now
    results["urls"][victim_url][run]["recovery_time"] = (end_time - start_time)

    recovered_url = recovery.readlines[0].chomp.split(": ")[1]
    if recovered_url == victim_url
      results["urls"][victim_url][run]["status"] = "pass"
      print "P "
    else
      results["urls"][victim_url][run]["status"] = "fail_bad_recovery"
      results["urls"][victim_url][run]["bad_recovery_url"] = recovered_url
      print "U "
    end
  end
  print "\n"
end

# Save the results
data_path = File.join(OUTPUT_DIR, "data.yaml")
File.open( data_path, "w" ) do |f|
  f.write(YAML.dump(results))
end

# Summarize the results:
puts "Training Time: #{results["training_time"]}"
passes = []
recording_failures = []
url_failures = []
results["urls"].each do |url, status_array|
  passes += status_array.reject { |s| s["status"] != "pass" }
  recording_failures += status_array.reject { |s| s["status"] != "fail_recording" }
  url_failures += status_array.reject { |s| s["status"] != "fail_bad_recovery" }
end
recovery_times = (passes + url_failures).map { |s| s["recovery_time"] }
maximum = recovery_times.max
average = recovery_times.inject(:+) / recovery_times.length
puts "Maximum Recovery Time: #{maximum}"
puts "Average Recovery Time: #{average}"
puts "Total Passes: #{passes.length}"
puts "Total Recording Failures: #{recording_failures.length}"
puts "Total URL Failures: #{url_failures.length}"

