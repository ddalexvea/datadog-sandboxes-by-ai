# Bug Report: `container_exclude_logs` Ignored When Using Image-Based Filtering

## Context

When using `container_include` with image-based patterns (e.g., `image:.*-prod.*`), the `container_exclude_logs` configuration is completely ignored in Datadog Agent versions 7.69.0 to 7.71.2. This is a regression from version 7.68.3. 

**The bug has been fixed in Agent 7.73.x via [PR #42647](https://github.com/DataDog/datadog-agent/pull/42647).**

**Full documentation available in the original repository:** [datadog-bug-container-log-exclusion-second-case](https://github.com/ddalexvea/datadog-bug-container-log-exclusion-second-case)

## Key Topics

- Container log exclusion bug in Agent 7.69.0-7.72.x
- Image-based filtering regression
- Fixed in Agent 7.73.2+
- Workaround: Downgrade to 7.68.3 or upgrade to 7.73.2+
