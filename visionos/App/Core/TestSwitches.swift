// SPDX-License-Identifier: GPL-2.0-or-later
//
// The switches of the settings' «Pruebas» section (there with «Modo diagnóstico» on): changes of the
// engine and of the app turned on and off between sessions. While a switch is on the emulator is
// given `variable=value` (AstroSettings.environment); off, nothing. It is kept in settings.txt as
// test_<id>=1 or 0.
//
// A new switch is one line of the table, in the form of the others and all on one line:
// tools/tests/test_switches_test.py reads this file and looks for the code that reads each variable.

import Foundation

struct TestSwitch: Identifiable {
    /// Its key in settings.txt is test_<id>: lowercase letters, digits and _. Not changed once given.
    let id: String
    /// What the switch is called, in Spanish.
    let title: String
    /// The environment variable the emulator is given while the switch is on, and its value.
    let variable: String
    let value: String
    /// The switch as it is until the player moves it.
    let on: Bool

    static let all: [TestSwitch] = [
        TestSwitch(id: "take_latest", title: "Presentación antigua (sin cola de 2)", variable: "ASTRO_TAKE_LATEST", value: "1", on: false),
        TestSwitch(id: "fetch_guards", title: "Cargas de buffer antiguas", variable: "VPGCN_FETCH_GUARDS", value: "1", on: false),
        TestSwitch(id: "depth_only_split", title: "Sin prepase fusionado", variable: "VPKENGINE_DEPTH_ONLY_SPLIT", value: "1", on: false),
        TestSwitch(id: "msaa_cut_samples_off", title: "Cortes MSAA con resolve (antiguo)", variable: "VPKENGINE_MSAA_CUT_SAMPLES_OFF", value: "1", on: false),
        TestSwitch(id: "program_memo_off", title: "Sin memo de programas", variable: "VPKENGINE_PROGRAM_MEMO_OFF", value: "1", on: false),
        TestSwitch(id: "bind_memo_off", title: "Sin memo de enlaces", variable: "VPKENGINE_BIND_MEMO_OFF", value: "1", on: false),
        TestSwitch(id: "hazard_memo_off", title: "Sin memo de hazards", variable: "VPKENGINE_HAZARD_MEMO_OFF", value: "1", on: false),
        TestSwitch(id: "frame_fold_off", title: "Sin plegado rápido de accesos", variable: "VPVK_FRAME_FOLD", value: "0", on: false),
        TestSwitch(id: "write_data_live", title: "WRITE_DATA sin anotar", variable: "VPKENGINE_WRITE_DATA_LIVE", value: "1", on: false),
        TestSwitch(id: "frame_hoist", title: "Adelantar dispatches (hoist)", variable: "VPVK_FRAME_HOIST", value: "1", on: false),
        TestSwitch(id: "barrier_order", title: "Cómputo ordenado por niveles", variable: "VPVK_BARRIER_ORDER", value: "1", on: false),
        TestSwitch(id: "vs_fastmath", title: "Vértices en fast math", variable: "VPKENGINE_VS_FASTMATH", value: "1", on: false),
        TestSwitch(id: "max_aniso", title: "Anisotropía máxima 4", variable: "VPKENGINE_MAX_ANISO", value: "4", on: false),
    ]
}
