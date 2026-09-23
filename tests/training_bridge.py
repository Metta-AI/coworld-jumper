"""Run the real headless bridge without a Metta checkout."""

import json
import subprocess
import sys


def request(process, command):
    process.stdin.write(json.dumps(command) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


def episode(process, seed):
    observation = request(process, {"kind": "reset", "seed": seed, "players": 3})
    assert observation["kind"] == "decision"
    first_encoding = request(process, {"kind": "encode"})
    assert len(first_encoding["values"]) == 100
    assert len(first_encoding["actions"]) == 6

    rejected = request(
        process,
        {"kind": "step", "decision_id": 0, "response": json.dumps({"mask": 255})},
    )
    assert rejected["kind"] == "rejected"
    steps = 0
    while observation["kind"] == "decision":
        response = request(process, {"kind": "teacher"})["response"]
        result = request(
            process,
            {"kind": "step", "decision_id": observation["decision_id"], "response": response},
        )
        assert result["kind"] == "accepted"
        observation = result["observation"]
        steps += 1
    assert steps == 1536
    assert observation["kind"] == "terminal"
    assert set(observation["scores"]) == {"0", "1", "2"}
    assert max(observation["scores"].values()) > 0
    return first_encoding, observation["scores"]


with subprocess.Popen(
    [sys.argv[1], sys.argv[2]],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
) as bridge:
    first = episode(bridge, "stable-seed")
    second = episode(bridge, "stable-seed")
    assert first == second

print("Jumper training bridge: two deterministic complete episodes")
