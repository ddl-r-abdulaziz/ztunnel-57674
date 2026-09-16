# fake-ztunnel

A patched build of [`ztunnel`](https://github.com/istio/ztunnel) that turns one specific, otherwise-hard-to-reproduce
race condition into something you can trigger deterministically, on demand, against a normal workload — with no changes
to that workload's own configuration.

This reproduces [istio/istio#57674](https://github.com/istio/istio/issues/57674).

This is mostly written using Claude Code.

## Demo

`demo/run-demo.sh` does everything below, end to end, on a local minikube cluster and shows the result. See [
`demo/README.md`](demo/README.md).

## The race this reproduces

The real `ztunnel` accepts a workload's very first connection (or DNS lookup routed through it) immediately, but doesn't
yet know that workload's identity or routing info. It holds the connection open for a short timeout while it waits for
that information to arrive, then either forwards the connection (if the info arrived in time) or drops it (if not). This
is a genuine race: whether it resolves one way or the other depends on cluster and control-plane timing at the moment a
workload starts, which makes it slow and unreliable to reproduce on purpose.

This build makes that outcome deterministic for whichever workloads you choose, so you can find out what your own
workload actually does when it happens — including cases where a workload doesn't crash, doesn't retry, and just quietly
treats the failure as permanent (e.g. caching a failed DNS lookup as "unreachable," or striking something off an
"available" list after one failed check at startup) — a class of bug that restart-count monitoring will never catch,
because there was no restart.

## What it changes

A single function, `wait_for_workload` in `src/state.rs`, is the one place both of ztunnel's workload-identity waits go
through: the outbound connection path, and the DNS-proxy path that resolves a request's *source*
workload. One small addition (`src/fake_race.rs`) intercepts calls to it for workloads in namespaces you choose, and
forces them to fail for a configurable window of time — starting from that workload's very first attempt. Everything
else is untouched, unpatched, stock `ztunnel` — every workload outside your chosen namespaces behaves exactly as it
would with a real, unmodified image.

## Behavior

- The first time any workload in a targeted namespace has a connection or DNS lookup wait on its identity, a window
  opens for that workload (identified by namespace + name).
- Every such wait for that workload, for as long as the window is open — including the one that opened it — is forced to
  fail, as if the real identity-wait had genuinely timed out. The failure surfaces through completely unmodified code:
  whatever a real timeout looks like to a client (a dropped connection, a DNS `SERVFAIL`, etc.) is exactly what this
  produces too, since nothing downstream of the fault injection is changed.
- Once the window's duration has elapsed since it opened, that workload is left alone permanently — every later wait for
  it (including one from a container restart) falls through to the real, unmodified logic. A workload that's fully
  replaced by a new pod with the same name and namespace (e.g. after a rollout) is treated as the same workload, since
  namespace + name is all this has to identify it by.
- Every forced failure is logged (`fake_race: forcing identity-wait
  timeout`, plus a distinct `fake_race: forced timeout waiting for
  workload ...` warning at the point of failure) with the workload's namespace, name, and how far into its window the
  call landed — ordinary
  `ztunnel` logs, nothing extra to retrieve.

## Configuration

Set as environment variables on the process:

| Variable                       | Default          | Meaning                                                                                                                                                                                    |
|--------------------------------|------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ZTUNNEL_FAKE_RACE_NAMESPACES` | unset (disabled) | Comma-separated list of namespaces to target. Workloads outside these namespaces are never affected. Leave unset to disable this behavior entirely and run as plain, unmodified `ztunnel`. |
| `ZTUNNEL_FAKE_RACE_HOLD_SECS`  | `6`              | How long, in seconds, a targeted workload's window of forced failures lasts, counted from its first attempt.                                                                               |

## Building

```
docker build -t quay.io/rabdulaziz/ztunnel-57674:dev .
```

Produces a runtime image with the patched binary at
`/usr/local/bin/ztunnel`, the same entrypoint a real `ztunnel` image exposes. Built from the pinned upstream tag this
fork is based on; rebase onto a newer tag by fetching from the `upstream` remote and replaying the one commit that adds
`src/fake_race.rs` and the small edit to `wait_for_workload` in `src/state.rs`.

## Publishing

No CI — build and push by hand:

```
docker build -t quay.io/rabdulaziz/ztunnel-57674:latest .
docker login quay.io
docker push quay.io/rabdulaziz/ztunnel-57674:latest
```

## Deploying to a cluster

Point an ambient-mode cluster's `ztunnel` at this image instead of the real one. Two ways to do that, from quickest to
most durable:

**Quickest (good for a one-off test):**

```
kubectl -n istio-system set image daemonset/ztunnel istio-proxy=quay.io/rabdulaziz/ztunnel-57674:latest
```

Takes effect immediately against whatever ambient install is already running. It's a direct edit of the `ztunnel`
DaemonSet, so it gets reverted the next time the installer reconciles or reinstalls ztunnel.

**Durable (survives a reinstall), via istioctl:**

```
istioctl install --set profile=ambient --set values.ztunnel.image=quay.io/rabdulaziz/ztunnel-57674:latest
```

The ztunnel Helm chart treats a full `registry/repo:tag` string in
`values.ztunnel.image` as a complete override, so this replaces the image at install time instead of just patching the
running DaemonSet. The exact value path can shift between Istio versions — check yours first with
`istioctl profile dump ambient | grep -A5 '^ztunnel:'`, and fall back to the
`kubectl set image` method above if it doesn't match.

Either way, no workload chart/pod-spec changes are needed — the fault injection is entirely on the proxy side. Once the
image is in place, set
`ZTUNNEL_FAKE_RACE_NAMESPACES` to your test namespace (s) and deploy a normal, unmodified workload into one of them.

## Demo

`demo/run-demo.sh` does all of the above end to end on a local minikube cluster and shows the result — see [
`demo/README.md`](demo/README.md).
