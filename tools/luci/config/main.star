#!/usr/bin/env lucicfg
#
# Copyright (C) 2021 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

"""LUCI project configuration for the production instance of LUCI.

After modifying this file execute it ('./main.star') to regenerate the configs.
"""

lucicfg.check_version("1.30.9", "Please update depot_tools")

luci.builder.defaults.experiments.set({
    "luci.recipes.use_python3": 100,
})

# Use LUCI Scheduler BBv2 names and add Scheduler realms configs.
lucicfg.enable_experiment("crbug.com/1182002")

# Tell lucicfg what files it is allowed to touch.
lucicfg.config(
    config_dir = "generated",
    fail_on_warnings = True,
    lint_checks = ["default"],
)

# TODO: Switch to project-scoped service account.

luci.project(
    name = "art",
    buildbucket = "cr-buildbucket.appspot.com",
    logdog = "luci-logdog.appspot.com",
    milo = "luci-milo.appspot.com",
    notify = "luci-notify.appspot.com",
    scheduler = "luci-scheduler.appspot.com",
    swarming = "chromium-swarm.appspot.com",
    acls = [
        # Publicly readable.
        acl.entry(
            roles = [
                acl.BUILDBUCKET_READER,
                acl.LOGDOG_READER,
                acl.PROJECT_CONFIGS_READER,
                acl.SCHEDULER_READER,
            ],
            groups = "all",
        ),
        acl.entry(
            roles = [
                acl.BUILDBUCKET_OWNER,
                acl.SCHEDULER_OWNER,
            ],
            groups = "project-art-admins",
        ),
        acl.entry(
            roles = acl.LOGDOG_WRITER,
            groups = "luci-logdog-chromium-writers",
        ),
    ],
    bindings = [
        luci.binding(
            roles = "role/swarming.poolOwner",
            groups = "project-art-admins",
        ),
        luci.binding(
            roles = "role/swarming.poolViewer",
            groups = "all",
        ),
    ],
)

# Per-service tweaks.
luci.logdog(gs_bucket = "chromium-luci-logdog")
luci.milo(logo = "https://storage.googleapis.com/chrome-infra-public/logo/art-logo.png")

# Allow admins to use LED and "Debug" button on every builder and bot.
luci.binding(
    realm = "@root",
    roles = "role/swarming.poolUser",
    groups = "project-art-admins",
)
luci.binding(
    realm = "@root",
    roles = "role/swarming.taskTriggerer",
    groups = "project-art-admins",
)

# Resources shared by all subprojects.

luci.realm(name = "pools/ci")
luci.bucket(name = "ci")

# Shadow bucket is needed for LED.
luci.bucket(
    name = "ci.shadow",
    shadows = "ci",
    bindings = [
        luci.binding(
            roles = "role/buildbucket.creator",
            users = ["art-ci-builder@chops-service-accounts.iam.gserviceaccount.com"],
        ),
        luci.binding(
            roles = "role/buildbucket.triggerer",
            users = ["art-ci-builder@chops-service-accounts.iam.gserviceaccount.com"],
        ),
    ],
    constraints = luci.bucket_constraints(
        pools = ["luci.art.ci"],
        service_accounts = ["art-ci-builder@chops-service-accounts.iam.gserviceaccount.com"],
    ),
    dynamic = True,
)

luci.notifier_template(
    name = "default",
    body = io.read_file("luci-notify.template"),
)

luci.console_view(
    name = "luci",
    repo = "https://android.googlesource.com/platform/art",
    title = "ART LUCI Console",
    refs = ["refs/heads/master"],
    include_experimental_builds = True,
)

luci.notifier(
    name = "art-team+chromium-buildbot",
    on_new_status = [
        "FAILURE",
        "INFRA_FAILURE",
    ],
    notify_emails = [
        "art-team+chromium-buildbot@google.com",
    ],
)

luci.gitiles_poller(
    name = "art",
    bucket = "ci",
    repo = "https://android.googlesource.com/platform/art",
    refs = ["refs/heads/master"],
)

luci.gitiles_poller(
    name = "libcore",
    bucket = "ci",
    repo = "https://android.googlesource.com/platform/libcore",
    refs = ["refs/heads/master"],
)

luci.gitiles_poller(
    name = "vogar",
    bucket = "ci",
    repo = "https://android.googlesource.com/platform/external/vogar",
    refs = ["refs/heads/master"],
)

luci.gitiles_poller(
    name = "manifest",
    bucket = "ci",
    repo = "https://android.googlesource.com/platform/manifest",
    refs = ["refs/heads/master-art"],
)

def ci_builder(name, category, short_name, dimensions, properties={}, hidden=False):
    luci.builder(
        name = name,
        bucket = "ci",
        executable = luci.recipe(
            cipd_package = "infra/recipe_bundles/chromium.googlesource.com/chromium/tools/build",
            cipd_version = "refs/heads/main",
            name = "art",
        ),
        dimensions = dimensions | {
            "pool": "luci.art.ci",
        },
        service_account = "art-ci-builder@chops-service-accounts.iam.gserviceaccount.com",

        # Maximum delay between scheduling a build and the build actually starting.
        # In a healthy state (enough free/idle devices), the delay is fairly small,
        # but if enough devices are offline, this timeout will cause INFRA_FAILURE.
        # Set the value reasonably high to prefer delayed builds over failing ones.
        # NB: LUCI also enforces (expiration_timeout + execution_timeout <= 47).
        expiration_timeout = 17 * time.hour,
        execution_timeout = 30 * time.hour,
        build_numbers = True,
        properties = properties,
        caches = [
            # Directory called "art" that persists from build to build (one per bot).
            # We can checkout and build in this directory to get fast incremental builds.
            swarming.cache("art", name = "art"),
        ],
        notifies = ["art-team+chromium-buildbot"] if not hidden else [],
        triggered_by = [
            "art",
            "libcore",
            "manifest",
            "vogar",
        ],
    )
    if not hidden:
        luci.console_view_entry(
            console_view = "luci",
            builder = name,
            category = category,
            short_name = short_name,
        )

def add_builder(name,
                mode,
                arch,
                bitness,
                debug=False,
                cc=True,
                gen_cc=True,
                gcstress=False,
                heap_poisoning=False):
    def check_arg(value, valid_values):
      if value not in valid_values:
        fail("Argument '{}' was expected to be on of {}".format(value, valid_values))
    check_arg(mode, ["target", "host", "qemu"])
    check_arg(arch, ["arm", "x86", "riscv"])
    check_arg(bitness, [32, 64])

    # Automatically create name based on the configuaration.
    default_name = mode + '.' + arch
    default_name += '.gsctress' if gcstress else ''
    default_name += '.poison' if heap_poisoning else ''
    default_name += '' if cc else '.ncc'
    default_name += '' if gen_cc else '.ngen'
    default_name += '.debug' if debug else '.ndebug'
    default_name += '.' + str(bitness)

    # Create abbreviated named which is used to create the LUCI console header.
    # TODO: Rename the builders to remove old device names and make it more uniform.
    short_name = name or default_name.replace(".", "-")
    short_name = short_name.replace("-x86-poison-debug", "-x86-psn")
    short_name = short_name.replace("-x86-gcstress-debug", "-x86-gcs")
    short_name = short_name.replace("-x86_64-poison-debug", "-x86_64-psn")
    short_name = short_name.replace("-x86_64", "-x64")
    short_name = short_name.replace("-ndebug-build_only", "-bo")
    short_name = short_name.replace("-non-gen-cc", "-ngen")
    short_name = short_name.replace("-debug", "-dbg")
    short_name = short_name.replace("-ndebug", "-ndbg")

    product = None
    if arch == "arm":
      product = "armv8" if bitness == 64 else "arm_krait"
    if arch == "riscv":
      product = "riscv64"

    dimensions = {"os": "Android" if mode == "target" else "Linux"}
    if mode == "target":
      if not cc:
        # Request devices running Android 24Q3 (`AP1A` builds) for
        # (`userfaultfd`-based) Concurrent Mark-Compact GC configurations.
        # Currently (as of 2024-08-22), the only devices within the device pool
        # allocated to ART that are running `AP1A` builds are Pixel 6 devices
        # (all other device types are running older Android versions), which are
        # also the only device model supporting `userfaultfd` among that pool.
        dimensions |= {"device_os": "A"}
      else:
        # Run all other configurations on Android S since it is the oldest we support.
        # Other than the `AP1A` builds above, all other devices are flashed to `SP2A`.
        # This avoids allocating `userfaultfd` devices for tests that don't need it.
        dimensions |= {"device_os": "S"}
    elif mode == "host":
      if name:
        dimensions |= {"os": "Ubuntu-20"}
      else:
        # Test the new host builders with new ubuntu.
        dimensions |= {"os": "Ubuntu-22"}
        dimensions |= {"cores": "8"}
    elif mode == "qemu":
      dimensions |= {"os": "Ubuntu-22"}
      dimensions |= {"cores": "16"}

    testrunner_args = ['--verbose', '--host'] if mode == 'host' else ['--target', '--verbose']
    testrunner_args += ['--debug'] if debug else ['--ndebug']
    testrunner_args += ['--gcstress'] if gcstress else []

    hidden = not name  # Hide the new builders for now.
    name = name or default_name

    properties = {
        "builder_group": "client.art",
        "bitness": bitness,
        "build_only": ("build_only" in name),
        "debug": debug,
        "device": None if mode == "host" else "-".join(name.split("-")[:2]),
        "on_virtual_machine": mode == "qemu",
        "product": product,
        "concurrent_collector": cc,
        "generational_cc": gen_cc,
        "gcstress": gcstress,
        "heap_poisoning": heap_poisoning,
        "testrunner_args": testrunner_args,
    }

    ci_builder(name,
               category="|".join(short_name.split("-")[:-1]),
               short_name=short_name.split("-")[-1],
               dimensions=dimensions,
               properties={k:v for k, v in properties.items() if v},
               hidden=hidden)

add_builder("angler-armv7-debug", 'target', 'arm', 32, debug=True)
add_builder("angler-armv7-non-gen-cc", 'target', 'arm', 32, debug=True, cc=False, gen_cc=False)
add_builder("angler-armv7-ndebug", 'target', 'arm', 32)
add_builder("angler-armv8-debug", 'target', 'arm', 64, debug=True)
add_builder("angler-armv8-non-gen-cc", 'target', 'arm', 64, debug=True, cc=False, gen_cc=False)
add_builder("angler-armv8-ndebug", 'target', 'arm', 64)
add_builder("bullhead-armv7-gcstress-ndebug", 'target', 'arm', 32, gcstress=True)
add_builder("bullhead-armv8-gcstress-debug", 'target', 'arm', 64, debug=True, gcstress=True)
add_builder("bullhead-armv8-gcstress-ndebug", 'target', 'arm', 64, gcstress=True)
add_builder("walleye-armv7-poison-debug", 'target', 'arm', 32, debug=True, heap_poisoning=True)
add_builder("walleye-armv8-poison-debug", 'target', 'arm', 64, debug=True, heap_poisoning=True)
add_builder("walleye-armv8-poison-ndebug", 'target', 'arm', 64, heap_poisoning=True)
add_builder("host-x86-cms", 'host', 'x86', 32, debug=True, cc=False, gen_cc=False)
add_builder("host-x86-debug", 'host', 'x86', 32, debug=True)
add_builder("host-x86-ndebug", 'host', 'x86', 32)
add_builder("host-x86-gcstress-debug", 'host', 'x86', 32, debug=True, gcstress=True)
add_builder("host-x86-poison-debug", 'host', 'x86', 32, debug=True, heap_poisoning=True)
add_builder("host-x86_64-cms", 'host', 'x86', 64, cc=False, debug=True, gen_cc=False)
add_builder("host-x86_64-debug", 'host', 'x86', 64, debug=True)
add_builder("host-x86_64-non-gen-cc", 'host', 'x86', 64, debug=True, gen_cc=False)
add_builder("host-x86_64-ndebug", 'host', 'x86', 64)
add_builder("host-x86_64-poison-debug", 'host', 'x86', 64, debug=True, heap_poisoning=True)
add_builder("qemu-armv8-ndebug", 'qemu', 'arm', 64)
add_builder("qemu-riscv64-ndebug", 'qemu', 'riscv', 64)

def add_builders():
  for bitness in [32, 64]:
    add_builder('', 'target', 'arm', bitness, debug=True, heap_poisoning=True)
    add_builder('', 'target', 'arm', bitness, heap_poisoning=True)
    add_builder('', 'host', 'x86', bitness, debug=True)
    add_builder('', 'host', 'x86', bitness)
    add_builder('', 'host', 'x86', bitness, debug=True, heap_poisoning=True)

add_builders()