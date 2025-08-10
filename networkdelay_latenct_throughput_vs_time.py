import re
import matplotlib.pyplot as plt

# Mapping file names to delay labels in correct order
files = {
    "baseline": "stress-output_baseline.txt",
    "1ms": "stress-output_1ms_90.log",
    "2ms": "stress-output_2ms_90.log",
    "5ms": "stress-output_5ms_90.log",
    "10ms": "stress-output_10ms_90.log",
    "25ms": "stress-output_25ms_90.log",
    "50ms": "stress-output_50ms_90.log",
    "75ms": "stress-output_75ms_90.log",
    "100ms": "stress-output_100ms_90.log"
}

# Function to parse stress log
def parse_log(filepath):
    seconds, ops, mean_lat = [], [], []
    with open(filepath, "r") as f:
        second = 0
        for line in f:
            match = re.match(
                r"total,\s+\d+,\s+([\d.]+),\s+\d+,\s+\d+,\s+([\d.]+),",
                line
            )
            if match:
                ops.append(float(match.group(1)))
                mean_lat.append(float(match.group(2)))
                seconds.append(second)
                second += 1
    return seconds, ops, mean_lat

# Parse all logs
data = {label: parse_log(path) for label, path in files.items()}

# Determine baseline throughput (average over all seconds)
baseline_ops = data["baseline"][1]
baseline_avg = sum(baseline_ops) / len(baseline_ops)

# Setup plot
fig, axs = plt.subplots(2, 1, figsize=(12, 8), sharex=True)

# --- Latency Plot ---
for label in sorted(data, key=lambda x: float(x.replace("ms", "0").replace("baseline", "-1"))):
    seconds, _, latency = data[label]
    axs[0].plot(seconds, latency, label=label)

axs[0].set_ylabel("Latency (ms)")
axs[0].set_title("Latency Over Time (With Baseline)")
axs[0].legend()
axs[0].grid(True, linestyle="--", alpha=0.6)

# --- Throughput Plot ---
for label in sorted(data, key=lambda x: float(x.replace("ms", "0").replace("baseline", "-1"))):
    seconds, ops, _ = data[label]
    axs[1].plot(seconds, ops, label=label)

axs[1].axhline(baseline_avg, color='gray', linestyle='--', alpha=0.7, label='Baseline Avg')
axs[1].set_ylabel("Throughput (ops/sec)")
axs[1].set_xlabel("Time (seconds)")
axs[1].set_title("Throughput Over Time (With Baseline)")
axs[1].set_ylim(3000, 10500)  # Zoom-in to reveal differences
axs[1].legend()
axs[1].grid(True, linestyle="--", alpha=0.6)

plt.tight_layout()
plt.savefig("latency_throughput_gradual.png")
plt.show()
