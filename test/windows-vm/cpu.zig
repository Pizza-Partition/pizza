// Shared by installation and every acceptance overlay. Keep full CPU validation:
// the named Intel CPU avoids the AMD Windows PMU path observed in crash dumps.
// The base Intel profile was validated on the AMD host used for the local trial.
// Optional vector/MSR flags unavailable in the runner pool are excluded below.
// Nested Intel VT-x capabilities cannot be supplied by AMD KVM.
pub const xml =
    "<features>" ++
    "<acpi/>" ++
    "<apic/>" ++
    "<smm state='off'/>" ++
    "<pmu state='off'/>" ++
    "</features>" ++
    "<cpu mode='custom' match='exact' check='full'>" ++
    "<model fallback='forbid'>Icelake-Server-v6" ++
    "</model>" ++
    // These optional Icelake flags were absent on the GitHub KVM runner.
    // Keep full validation while exposing only the supported feature set.
    "<feature policy='disable' name='avx512f'/>" ++
    "<feature policy='disable' name='avx512dq'/>" ++
    "<feature policy='disable' name='avx512ifma'/>" ++
    "<feature policy='disable' name='avx512cd'/>" ++
    "<feature policy='disable' name='avx512bw'/>" ++
    "<feature policy='disable' name='avx512vl'/>" ++
    "<feature policy='disable' name='avx512vbmi'/>" ++
    "<feature policy='disable' name='avx512vbmi2'/>" ++
    "<feature policy='disable' name='gfni'/>" ++
    "<feature policy='disable' name='avx512vnni'/>" ++
    "<feature policy='disable' name='avx512bitalg'/>" ++
    "<feature policy='disable' name='avx512-vpopcntdq'/>" ++
    "<feature policy='disable' name='pku'/>" ++
    "<feature policy='disable' name='spec-ctrl'/>" ++
    "<feature policy='disable' name='ssbd'/>" ++
    "<feature policy='disable' name='wbnoinvd'/>" ++
    "<feature policy='disable' name='pcid'/>" ++
    "<feature policy='disable' name='la57'/>" ++
    "<feature policy='disable' name='ibrs-all'/>" ++
    "<feature policy='disable' name='taa-no'/>" ++
    "<feature policy='require' name='hypervisor'/>" ++
    "<feature policy='disable' name='vmx'/>" ++
    "<feature policy='disable' name='vmx-ins-outs'/>" ++
    "<feature policy='disable' name='vmx-true-ctls'/>" ++
    "<feature policy='disable' name='vmx-store-lma'/>" ++
    "<feature policy='disable' name='vmx-activity-hlt'/>" ++
    "<feature policy='disable' name='vmx-vmwrite-vmexit-fields'/>" ++
    "<feature policy='disable' name='vmx-apicv-xapic'/>" ++
    "<feature policy='disable' name='vmx-ept'/>" ++
    "<feature policy='disable' name='vmx-desc-exit'/>" ++
    "<feature policy='disable' name='vmx-rdtscp-exit'/>" ++
    "<feature policy='disable' name='vmx-apicv-x2apic'/>" ++
    "<feature policy='disable' name='vmx-vpid'/>" ++
    "<feature policy='disable' name='vmx-wbinvd-exit'/>" ++
    "<feature policy='disable' name='vmx-unrestricted-guest'/>" ++
    "<feature policy='disable' name='vmx-apicv-register'/>" ++
    "<feature policy='disable' name='vmx-apicv-vid'/>" ++
    "<feature policy='disable' name='vmx-rdrand-exit'/>" ++
    "<feature policy='disable' name='vmx-invpcid-exit'/>" ++
    "<feature policy='disable' name='vmx-vmfunc'/>" ++
    "<feature policy='disable' name='vmx-shadow-vmcs'/>" ++
    "<feature policy='disable' name='vmx-rdseed-exit'/>" ++
    "<feature policy='disable' name='vmx-pml'/>" ++
    "<feature policy='disable' name='vmx-xsaves'/>" ++
    "<feature policy='disable' name='vmx-ept-execonly'/>" ++
    "<feature policy='disable' name='vmx-page-walk-4'/>" ++
    "<feature policy='disable' name='vmx-page-walk-5'/>" ++
    "<feature policy='disable' name='vmx-ept-2mb'/>" ++
    "<feature policy='disable' name='vmx-ept-1gb'/>" ++
    "<feature policy='disable' name='vmx-invept'/>" ++
    "<feature policy='disable' name='vmx-eptad'/>" ++
    "<feature policy='disable' name='vmx-invept-single-context'/>" ++
    "<feature policy='disable' name='vmx-invept-all-context'/>" ++
    "<feature policy='disable' name='vmx-invvpid-single-addr'/>" ++
    "<feature policy='disable' name='vmx-invvpid-all-context'/>" ++
    "<feature policy='disable' name='vmx-invvpid-single-context-noglobals'/>" ++
    "<feature policy='disable' name='vmx-intr-exit'/>" ++
    "<feature policy='disable' name='vmx-nmi-exit'/>" ++
    "<feature policy='disable' name='vmx-vnmi'/>" ++
    "<feature policy='disable' name='vmx-preemption-timer'/>" ++
    "<feature policy='disable' name='vmx-posted-intr'/>" ++
    "<feature policy='disable' name='vmx-vintr-pending'/>" ++
    "<feature policy='disable' name='vmx-tsc-offset'/>" ++
    "<feature policy='disable' name='vmx-hlt-exit'/>" ++
    "<feature policy='disable' name='vmx-invlpg-exit'/>" ++
    "<feature policy='disable' name='vmx-mwait-exit'/>" ++
    "<feature policy='disable' name='vmx-rdpmc-exit'/>" ++
    "<feature policy='disable' name='vmx-rdtsc-exit'/>" ++
    "<feature policy='disable' name='vmx-cr3-load-noexit'/>" ++
    "<feature policy='disable' name='vmx-cr3-store-noexit'/>" ++
    "<feature policy='disable' name='vmx-cr8-load-exit'/>" ++
    "<feature policy='disable' name='vmx-cr8-store-exit'/>" ++
    "<feature policy='disable' name='vmx-flexpriority'/>" ++
    "<feature policy='disable' name='vmx-vnmi-pending'/>" ++
    "<feature policy='disable' name='vmx-movdr-exit'/>" ++
    "<feature policy='disable' name='vmx-io-exit'/>" ++
    "<feature policy='disable' name='vmx-io-bitmap'/>" ++
    "<feature policy='disable' name='vmx-mtf'/>" ++
    "<feature policy='disable' name='vmx-msr-bitmap'/>" ++
    "<feature policy='disable' name='vmx-monitor-exit'/>" ++
    "<feature policy='disable' name='vmx-pause-exit'/>" ++
    "<feature policy='disable' name='vmx-secondary-ctls'/>" ++
    "<feature policy='disable' name='vmx-exit-nosave-debugctl'/>" ++
    "<feature policy='disable' name='vmx-exit-load-perf-global-ctrl'/>" ++
    "<feature policy='disable' name='vmx-exit-ack-intr'/>" ++
    "<feature policy='disable' name='vmx-exit-save-pat'/>" ++
    "<feature policy='disable' name='vmx-exit-load-pat'/>" ++
    "<feature policy='disable' name='vmx-exit-save-efer'/>" ++
    "<feature policy='disable' name='vmx-exit-load-efer'/>" ++
    "<feature policy='disable' name='vmx-exit-save-preemption-timer'/>" ++
    "<feature policy='disable' name='vmx-entry-noload-debugctl'/>" ++
    "<feature policy='disable' name='vmx-entry-ia32e-mode'/>" ++
    "<feature policy='disable' name='vmx-entry-load-perf-global-ctrl'/>" ++
    "<feature policy='disable' name='vmx-entry-load-pat'/>" ++
    "<feature policy='disable' name='vmx-entry-load-efer'/>" ++
    "<feature policy='disable' name='vmx-eptp-switching'/>" ++
    "</cpu>" ++
    "<clock offset='localtime'/>";
