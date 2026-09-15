// Copyright Istio Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Deterministic fault injection for the workload identity-wait timeout in
//! `state::DemandProxyState::wait_for_workload`.
//!
//! Normally, a workload's very first connection (or DNS lookup routed
//! through this proxy) can race a real identity push: if this proxy hasn't
//! yet learned the workload's identity/routing info, it holds the
//! connection open for a timeout and then drops it. That race is
//! probabilistic and depends on cluster/control-plane timing, which makes
//! it hard for anyone to deliberately test how their own workload behaves
//! when it happens.
//!
//! This module makes that timeout deterministic and repeatable, scoped to
//! one or more chosen namespaces, so it can be exercised on demand against
//! an otherwise completely normal workload with no changes to that
//! workload's own configuration.
//!
//! Behavior: the first time any workload in a targeted namespace asks to
//! wait for its own identity, a window starts for that specific workload
//! (identified by namespace + name). Every such wait — including that
//! first one — is forced to fail for as long as the window is open. Once
//! the configured window duration has elapsed since it started, that
//! workload is left alone permanently: it falls back to the real,
//! unmodified waiting logic for the rest of its lifetime, even if it is
//! later restarted. A workload that is fully replaced (a new pod, e.g.
//! after a rollout) is identified by the same namespace + name, so it
//! reuses the same, already-elapsed window rather than getting a fresh one
//! — this module only tracks name/namespace, since that's all the caller
//! has available to it.
//!
//! Workloads outside the targeted namespaces are entirely unaffected; this
//! module changes nothing about their behavior.
//!
//! Configuration is via environment variables, read once on first use:
//!
//! - `ZTUNNEL_FAKE_RACE_NAMESPACES`: comma-separated list of namespaces to
//!   target. Unset or empty disables this module entirely.
//! - `ZTUNNEL_FAKE_RACE_HOLD_SECS`: how long, in seconds, a targeted
//!   workload's window of forced failures lasts, starting from its first
//!   attempt. Defaults to 6 (deliberately above the 5s identity-wait
//!   timeout this is standing in for).

use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::env;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::state::WorkloadInfo;

const NAMESPACES_ENV: &str = "ZTUNNEL_FAKE_RACE_NAMESPACES";
const HOLD_SECS_ENV: &str = "ZTUNNEL_FAKE_RACE_HOLD_SECS";
const DEFAULT_HOLD_SECS: u64 = 6;

fn target_namespaces() -> &'static [String] {
    static NAMESPACES: Lazy<Vec<String>> = Lazy::new(|| {
        env::var(NAMESPACES_ENV)
            .ok()
            .map(|raw| {
                raw.split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default()
    });
    &NAMESPACES
}

fn hold_duration() -> Duration {
    static HOLD: Lazy<Duration> = Lazy::new(|| {
        let secs = env::var(HOLD_SECS_ENV)
            .ok()
            .and_then(|raw| raw.parse::<u64>().ok())
            .unwrap_or(DEFAULT_HOLD_SECS);
        Duration::from_secs(secs)
    });
    *HOLD
}

/// Per-workload window state, keyed by "namespace/name". A present entry
/// means that workload has had its window started; the value is when.
/// Entries are never removed, so a workload whose window has already
/// elapsed stays that way permanently.
static WINDOWS: Lazy<Mutex<HashMap<String, Instant>>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn window_key(wl: &WorkloadInfo) -> String {
    format!("{}/{}", wl.namespace, wl.name)
}

/// Returns true if the caller's identity-wait for `wl` should be forced to
/// fail as though it had genuinely timed out. Starts this workload's
/// window on the first call for it, if it's in a targeted namespace.
pub fn should_force_timeout(wl: &WorkloadInfo) -> bool {
    if !target_namespaces().iter().any(|ns| ns == &wl.namespace) {
        return false;
    }

    let hold = hold_duration();
    let now = Instant::now();
    let started_at = {
        let mut windows = WINDOWS.lock().expect("fake_race windows lock poisoned");
        *windows.entry(window_key(wl)).or_insert(now)
    };
    let elapsed = now.duration_since(started_at);

    if elapsed < hold {
        tracing::info!(
            workload.namespace = %wl.namespace,
            workload.name = %wl.name,
            elapsed_ms = elapsed.as_millis() as u64,
            window_ms = hold.as_millis() as u64,
            "fake_race: forcing identity-wait timeout"
        );
        true
    } else {
        false
    }
}
