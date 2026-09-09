local mod = get_mod("NoBrainer")
local settings = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/modules/Settings")

local color_options = {
    {
        text = "opt_heat_cyan",
        value = "cyan",
    },
    {
        text = "opt_heat_amber",
        value = "amber",
    },
    {
        text = "opt_heat_white",
        value = "white",
    },
    {
        text = "opt_heat_toxin",
        value = "toxin",
    },
}

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "analysis_mode",
                type = "dropdown",
                default_value = settings.defaults.analysis_mode,
                options = {
                    {
                        text = "opt_mode_gabriel_graph",
                        value = "gabriel_graph",
                    },
                    {
                        text = "opt_mode_wavefront",
                        value = "wavefront",
                    },
                    {
                        text = "opt_mode_heat_method",
                        value = "heat_method",
                    },
                    {
                        text = "opt_mode_ball_pivot",
                        value = "ball_pivot",
                    },
                    {
                        text = "opt_mode_homology",
                        value = "homology",
                    },
                    {
                        text = "opt_mode_tsdf_dual",
                        value = "tsdf_dual",
                    },
                    {
                        text = "opt_mode_mls_implicit",
                        value = "mls_implicit",
                    },
                    {
                        text = "opt_mode_spectral_graph",
                        value = "spectral_graph",
                    },
                    {
                        text = "opt_mode_pca_curvature",
                        value = "pca_curvature",
                    },
                    {
                        text = "opt_mode_ransac_planes",
                        value = "ransac_planes",
                    },
                    {
                        text = "opt_mode_procedural_math",
                        value = "procedural_math",
                    },
                },
            },
            {
                setting_id = "performance_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "global_frame_budget",
                        type = "numeric",
                        default_value = settings.defaults.global_frame_budget,
                        range = { 256, 60000 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "global_draw_limit_enabled",
                        type = "checkbox",
                        default_value = settings.defaults.global_draw_limit_enabled,
                    },
                    {
                        setting_id = "global_max_draw_lines",
                        type = "numeric",
                        default_value = settings.defaults.global_max_draw_lines,
                        range = { 16, 10000 },
                        decimals_number = 0,
                    },
                },
            },
            {
                setting_id = "nb_scan_key",
                type = "keybind",
                default_value = {},
                keybind_trigger = "pressed",
                keybind_type = "function_call",
                function_name = "nb_scan",
            },
            {
                setting_id = "nb_radial_scan_key",
                type = "keybind",
                default_value = {},
                keybind_trigger = "pressed",
                keybind_type = "function_call",
                function_name = "nb_radial_scan",
            },
            {
                setting_id = "nb_clear_key",
                type = "keybind",
                default_value = {},
                keybind_trigger = "pressed",
                keybind_type = "function_call",
                function_name = "nb_clear",
            },
            {
                setting_id = "darkness_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "darkness_enabled",
                        type = "checkbox",
                        default_value = settings.defaults.darkness_enabled,
                    },
                    {
                        setting_id = "gamma_level",
                        type = "numeric",
                        default_value = settings.defaults.gamma_level,
                        range = { -15, 0 },
                        decimals_number = 0,
                    },
                },
            },
            {
                setting_id = "scan_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "h_res",
                        type = "numeric",
                        default_value = settings.defaults.h_res,
                        range = { 10, 300 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "v_res",
                        type = "numeric",
                        default_value = settings.defaults.v_res,
                        range = { 10, 200 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "h_fov",
                        type = "numeric",
                        default_value = settings.defaults.h_fov,
                        range = { 10, 180 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "v_fov",
                        type = "numeric",
                        default_value = settings.defaults.v_fov,
                        range = { 10, 180 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "max_range",
                        type = "numeric",
                        default_value = settings.defaults.max_range,
                        range = { 5, 200 },
                        decimals_number = 0,
                    },
                },
            },
            {
                setting_id = "geometry_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "dot_size",
                        type = "numeric",
                        default_value = settings.defaults.dot_size,
                        range = { 1, 100 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "dot_duration",
                        type = "numeric",
                        default_value = settings.defaults.dot_duration,
                        range = { 1, 120 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "color_scheme",
                        type = "dropdown",
                        default_value = settings.defaults.color_scheme,
                        options = {
                            {
                                text = "opt_scheme_classic",
                                value = "classic",
                            },
                            {
                                text = "opt_scheme_mono",
                                value = "mono",
                            },
                            {
                                text = "opt_scheme_infrared",
                                value = "infrared",
                            },
                            {
                                text = "opt_scheme_amber",
                                value = "amber",
                            },
                            {
                                text = "opt_scheme_toxin",
                                value = "toxin",
                            },
                            {
                                text = "opt_scheme_rainbow",
                                value = "rainbow",
                            },
                        },
                    },
                    {
                        setting_id = "lines_per_dot",
                        type = "dropdown",
                        default_value = settings.defaults.lines_per_dot,
                        options = {
                            {
                                text = "opt_one_line",
                                value = 1,
                            },
                            {
                                text = "opt_two_lines",
                                value = 2,
                            },
                            {
                                text = "opt_three_lines",
                                value = 3,
                            },
                        },
                    },
                    {
                        setting_id = "mesh_link_distance",
                        type = "numeric",
                        default_value = settings.defaults.mesh_link_distance,
                        range = { 0.2, 10.0 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "line_surface_lift",
                        type = "numeric",
                        default_value = settings.defaults.line_surface_lift,
                        range = { 0.0, 0.15 },
                        decimals_number = 3,
                    },
                    {
                        setting_id = "max_dots",
                        type = "numeric",
                        default_value = settings.defaults.max_dots,
                        range = { 1000, 150000 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "recycle_oldest",
                        type = "checkbox",
                        default_value = settings.defaults.recycle_oldest,
                    },
                },
            },
            {
                setting_id = "topology_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "max_epsilon",
                        type = "numeric",
                        default_value = settings.defaults.max_epsilon,
                        range = { 0.2, 10.0 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "min_persistence",
                        type = "numeric",
                        default_value = settings.defaults.min_persistence,
                        range = { 0.0, 5.0 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "max_cycles",
                        type = "numeric",
                        default_value = settings.defaults.max_cycles,
                        range = { 1, 50 },
                        decimals_number = 0,
                    },
                },
            },
            {
                setting_id = "surface_sampler_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "heat_radius",
                        type = "numeric",
                        default_value = settings.defaults.heat_radius,
                        range = { 5, 60 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "heat_front_points",
                        type = "numeric",
                        default_value = settings.defaults.heat_front_points,
                        range = { 24, 256 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "heat_step_length",
                        type = "numeric",
                        default_value = settings.defaults.heat_step_length,
                        range = { 0.10, 0.60 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "heat_probe_distance",
                        type = "numeric",
                        default_value = settings.defaults.heat_probe_distance,
                        range = { 0.18, 1.00 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "heat_surface_lift",
                        type = "numeric",
                        default_value = settings.defaults.heat_surface_lift,
                        range = { 0.005, 0.15 },
                        decimals_number = 3,
                    },
                },
            },
            {
                setting_id = "heat_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "heat_speed",
                        type = "numeric",
                        default_value = settings.defaults.heat_speed,
                        range = { 1, 20 },
                        decimals_number = 1,
                    },
                    {
                        setting_id = "heat_trails",
                        type = "numeric",
                        default_value = settings.defaults.heat_trails,
                        range = { 1, 8 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "heat_trail_spacing",
                        type = "numeric",
                        default_value = settings.defaults.heat_trail_spacing,
                        range = { 0.15, 2.0 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "heat_color",
                        type = "dropdown",
                        default_value = settings.defaults.heat_color,
                        options = color_options,
                    },
                    {
                        setting_id = "heat_loop",
                        type = "checkbox",
                        default_value = settings.defaults.heat_loop,
                    },
                },
            },
            {
                setting_id = "bpa_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "bpa_sample_spacing",
                        type = "numeric",
                        default_value = settings.defaults.bpa_sample_spacing,
                        range = { 0.35, 3.00 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "bpa_ball_radius",
                        type = "numeric",
                        default_value = settings.defaults.bpa_ball_radius,
                        range = { 0.50, 4.50 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "bpa_scan_time",
                        type = "numeric",
                        default_value = settings.defaults.bpa_scan_time,
                        range = { 1, 60 },
                        decimals_number = 1,
                    },
                    {
                        setting_id = "bpa_duration",
                        type = "numeric",
                        default_value = settings.defaults.bpa_duration,
                        range = { 1, 180 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "bpa_color",
                        type = "dropdown",
                        default_value = settings.defaults.bpa_color,
                        options = color_options,
                    },
                },
            },
            {
                setting_id = "tsdf_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "tsdf_voxel_size",
                        type = "numeric",
                        default_value = settings.defaults.tsdf_voxel_size,
                        range = { 0.15, 1.00 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "tsdf_truncation",
                        type = "numeric",
                        default_value = settings.defaults.tsdf_truncation,
                        range = { 0.20, 2.00 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "tsdf_max_voxels",
                        type = "numeric",
                        default_value = settings.defaults.tsdf_max_voxels,
                        range = { 10000, 150000 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "tsdf_color",
                        type = "dropdown",
                        default_value = settings.defaults.tsdf_color,
                        options = color_options,
                    },
                },
            },
            {
                setting_id = "point_cloud_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "pc_max_points",
                        type = "numeric",
                        default_value = settings.defaults.pc_max_points,
                        range = { 500, 15000 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "pc_sample_spacing",
                        type = "numeric",
                        default_value = settings.defaults.pc_sample_spacing,
                        range = { 0.08, 1.50 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "pc_scale",
                        type = "numeric",
                        default_value = settings.defaults.pc_scale,
                        range = { 0.30, 5.00 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "pc_color",
                        type = "dropdown",
                        default_value = settings.defaults.pc_color,
                        options = color_options,
                    },
                },
            },
            {
                setting_id = "procedural_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "proc_pattern",
                        type = "dropdown",
                        default_value = settings.defaults.proc_pattern,
                        options = {
                            {
                                text = "opt_proc_lorenz",
                                value = "lorenz",
                            },
                            {
                                text = "opt_proc_rossler",
                                value = "rossler",
                            },
                            {
                                text = "opt_proc_aizawa",
                                value = "aizawa",
                            },
                            {
                                text = "opt_proc_thomas",
                                value = "thomas",
                            },
                            {
                                text = "opt_proc_dadras",
                                value = "dadras",
                            },
                            {
                                text = "opt_proc_halvorsen",
                                value = "halvorsen",
                            },
                            {
                                text = "opt_proc_chen",
                                value = "chen",
                            },
                            {
                                text = "opt_proc_rabinovich",
                                value = "rabinovich",
                            },
                            {
                                text = "opt_proc_chua",
                                value = "chua",
                            },
                            {
                                text = "opt_proc_rikitake",
                                value = "rikitake",
                            },
                            {
                                text = "opt_proc_nose_hoover",
                                value = "nose_hoover",
                            },
                            {
                                text = "opt_proc_duffing",
                                value = "duffing",
                            },
                            {
                                text = "opt_proc_de_jong",
                                value = "de_jong",
                            },
                            {
                                text = "opt_proc_clifford_map",
                                value = "clifford_map",
                            },
                            {
                                text = "opt_proc_ikeda",
                                value = "ikeda",
                            },
                            {
                                text = "opt_proc_trefoil",
                                value = "trefoil",
                            },
                            {
                                text = "opt_proc_torus_knot",
                                value = "torus_knot",
                            },
                            {
                                text = "opt_proc_lissajous",
                                value = "lissajous",
                            },
                            {
                                text = "opt_proc_hopf_links",
                                value = "hopf_links",
                            },
                            {
                                text = "opt_proc_mobius",
                                value = "mobius",
                            },
                            {
                                text = "opt_proc_klein",
                                value = "klein",
                            },
                            {
                                text = "opt_proc_clifford_torus",
                                value = "clifford_torus",
                            },
                            {
                                text = "opt_proc_spherical_harmonic",
                                value = "spherical_harmonic",
                            },
                            {
                                text = "opt_proc_enneper",
                                value = "enneper",
                            },
                            {
                                text = "opt_proc_helicoid",
                                value = "helicoid",
                            },
                            {
                                text = "opt_proc_catenoid",
                                value = "catenoid",
                            },
                            {
                                text = "opt_proc_roman",
                                value = "roman",
                            },
                            {
                                text = "opt_proc_superformula",
                                value = "superformula",
                            },
                            {
                                text = "opt_proc_gyroid_contours",
                                value = "gyroid_contours",
                            },
                            {
                                text = "opt_proc_fibonacci_sphere",
                                value = "fibonacci_sphere",
                            },
                            {
                                text = "opt_proc_sierpinski_tetra",
                                value = "sierpinski_tetra",
                            },
                            {
                                text = "opt_proc_abc_flow",
                                value = "abc_flow",
                            },
                        },
                    },
                    {
                        setting_id = "proc_scale",
                        type = "numeric",
                        default_value = settings.defaults.proc_scale,
                        range = { 0.25, 6.0 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "proc_detail",
                        type = "numeric",
                        default_value = settings.defaults.proc_detail,
                        range = { 0.5, 4.0 },
                        decimals_number = 1,
                    },
                    {
                        setting_id = "proc_distance",
                        type = "numeric",
                        default_value = settings.defaults.proc_distance,
                        range = { 1.5, 12.0 },
                        decimals_number = 1,
                    },
                    {
                        setting_id = "proc_color",
                        type = "dropdown",
                        default_value = settings.defaults.proc_color,
                        options = color_options,
                    },
                },
            },
            {
                setting_id = "nav_geodesic_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "nav_radius",
                        type = "numeric",
                        default_value = settings.defaults.nav_radius,
                        range = { 5, 60 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "nav_speed",
                        type = "numeric",
                        default_value = settings.defaults.nav_speed,
                        range = { 1, 20 },
                        decimals_number = 1,
                    },
                    {
                        setting_id = "nav_trails",
                        type = "numeric",
                        default_value = settings.defaults.nav_trails,
                        range = { 1, 8 },
                        decimals_number = 0,
                    },
                    {
                        setting_id = "nav_trail_spacing",
                        type = "numeric",
                        default_value = settings.defaults.nav_trail_spacing,
                        range = { 0.15, 2.0 },
                        decimals_number = 2,
                    },
                    {
                        setting_id = "nav_surface_lift",
                        type = "numeric",
                        default_value = settings.defaults.nav_surface_lift,
                        range = { 0.005, 0.15 },
                        decimals_number = 3,
                    },
                    {
                        setting_id = "nav_color",
                        type = "dropdown",
                        default_value = settings.defaults.nav_color,
                        options = color_options,
                    },
                    {
                        setting_id = "nav_loop",
                        type = "checkbox",
                        default_value = settings.defaults.nav_loop,
                    },
                },
            },
        },
    },
}
