return {
    mod_name = {
        en = "{#color(70,220,255)}NoBrainer{#reset()}",
    },
    mod_description = {
        en = "Mathematical mapping and LineObject visualizers for Darktide: topology, surface reconstruction, collision geometry, point-cloud analysis, chaotic systems, knots, parametric surfaces, and flow fields.",
    },

    analysis_mode = {
        en = "{#color(70,220,255)}Active mapping method{#reset()}",
    },
    opt_mode_homology = {
        en = "Homology scanner + LIDAR",
    },
    opt_mode_wavefront = {
        en = "Geodesic Waves",
    },
    opt_mode_heat_method = {
        en = "Geodesic Heat Waves",
    },
    opt_mode_ball_pivot = {
        en = "Ball Pivot Mapping",
    },
    opt_mode_tsdf_dual = {
        en = "TSDF + Dual Contouring",
    },
    opt_mode_gabriel_graph = {
        en = "Gabriel Proximity Graph",
    },
    opt_mode_pca_curvature = {
        en = "PCA Surface Variation Frames",
    },
    opt_mode_ransac_planes = {
        en = "RANSAC Structural Planes",
    },
    opt_mode_mls_implicit = {
        en = "IMLS Oriented Surface",
    },
    opt_mode_spectral_graph = {
        en = "Spectral Graph Field",
    },
    opt_mode_procedural_math = {
        en = "Equation / Geometry Visualizer (standalone)",
    },

    performance_group = {
        en = "Global performance",
    },
    global_frame_budget = {
        en = "Maximum mapping work per frame",
    },
    global_draw_limit_enabled = {
        en = "Limit line submissions per frame",
    },
    global_max_draw_lines = {
        en = "Maximum line submissions per frame",
    },

    nb_scan_key = {
        en = "Primary action (FOV scan / mapping pulse)",
    },
    nb_radial_scan_key = {
        en = "Secondary action (360 scan / mapping pulse)",
    },
    nb_clear_key = {
        en = "Clear active mapping method",
    },

    darkness_group = {
        en = "Global darkness / gamma",
    },
    darkness_enabled = {
        en = "Darkness enabled",
    },
    gamma_level = {
        en = "Gamma level",
    },

    scan_group = {
        en = "Shared raycast scan (Homology scanner + LIDAR / TSDF + Dual Contouring / point-cloud methods)",
    },
    h_res = {
        en = "Horizontal rays",
    },
    v_res = {
        en = "Vertical rays",
    },
    h_fov = {
        en = "Horizontal FOV",
    },
    v_fov = {
        en = "Vertical FOV",
    },
    max_range = {
        en = "Ray range (m)",
    },

    geometry_group = {
        en = "{#color(70,220,255)}Homology scanner + LIDAR: retained geometry{#reset()}",
    },
    dot_size = {
        en = "Dot size",
    },
    dot_duration = {
        en = "Dots + scan lines lifetime (s)",
    },
    color_scheme = {
        en = "Geometry color scheme",
    },
    lines_per_dot = {
        en = "Lines per dot",
    },
    mesh_link_distance = {
        en = "Maximum scan-grid link distance (m)",
    },
    line_surface_lift = {
        en = "Surface lift (m)",
    },
    max_dots = {
        en = "Maximum retained scan points",
    },
    recycle_oldest = {
        en = "Recycle oldest geometry at cap",
    },

    topology_group = {
        en = "{#color(220,120,255)}Homology scanner + LIDAR: H1 analysis{#reset()}",
    },
    max_epsilon = {
        en = "Maximum filtration epsilon (m)",
    },
    min_persistence = {
        en = "Minimum H1 persistence (m)",
    },
    max_cycles = {
        en = "Maximum highlighted H1 cycles",
    },

    surface_sampler_group = {
        en = "Collision-surface sampling (Geodesic Waves + Ball Pivot Mapping)",
    },
    heat_radius = {
        en = "Surface exploration radius (m)",
    },
    heat_front_points = {
        en = "Surface front density",
    },
    heat_step_length = {
        en = "Surface sample step (m)",
    },
    heat_probe_distance = {
        en = "Surface adhesion probe (m)",
    },
    heat_surface_lift = {
        en = "Collision clearance (m)",
    },

    heat_group = {
        en = "{#color(70,220,255)}Geodesic Waves{#reset()}",
    },
    heat_speed = {
        en = "Wave speed (m/s)",
    },
    heat_trails = {
        en = "Trailing contours",
    },
    heat_trail_spacing = {
        en = "Contour spacing (m)",
    },
    heat_color = {
        en = "Wave color",
    },
    heat_loop = {
        en = "Loop pulse",
    },

    bpa_group = {
        en = "{#color(255,180,45)}Ball Pivot Mapping{#reset()}",
    },
    bpa_sample_spacing = {
        en = "Surface sample thinning distance (m)",
    },
    bpa_ball_radius = {
        en = "Base pivot ball radius (m)",
    },
    bpa_scan_time = {
        en = "Outward scan reveal time (s)",
    },
    bpa_duration = {
        en = "Reconstructed mesh lifetime (s)",
    },
    bpa_color = {
        en = "Mesh color (next reconstruction)",
    },

    tsdf_group = {
        en = "{#color(230,230,230)}TSDF + Dual Contouring{#reset()}",
    },
    tsdf_voxel_size = {
        en = "Voxel size (m)",
    },
    tsdf_truncation = {
        en = "TSDF truncation distance (m)",
    },
    tsdf_max_voxels = {
        en = "Maximum sparse TSDF samples",
    },
    tsdf_color = {
        en = "Dual Contour mesh color",
    },

    point_cloud_group = {
        en = "{#color(90,235,110)}Point-cloud methods{#reset()}: Gabriel / PCA / RANSAC / IMLS / Spectral",
    },
    pc_max_points = {
        en = "Maximum retained point-cloud samples",
    },
    pc_sample_spacing = {
        en = "Point-cloud sample spacing (m)",
    },
    pc_scale = {
        en = "Feature / neighborhood scale (m)",
    },
    pc_color = {
        en = "Primary point-cloud visualization color",
    },

    procedural_group = {
        en = "Equation / Geometry Visualizer: standalone shapes (no scan required)",
    },
    proc_pattern = {
        en = "Curve / surface / dynamical system",
    },
    proc_scale = {
        en = "World scale",
    },
    proc_detail = {
        en = "Detail / integration length",
    },
    proc_distance = {
        en = "Distance in front of camera (m)",
    },
    proc_color = {
        en = "Pattern color",
    },
    opt_proc_lorenz = {
        en = "Lorenz attractor",
    },
    opt_proc_rossler = {
        en = "Rössler attractor",
    },
    opt_proc_aizawa = {
        en = "Aizawa attractor",
    },
    opt_proc_thomas = {
        en = "Thomas cyclic attractor",
    },
    opt_proc_dadras = {
        en = "Dadras attractor",
    },
    opt_proc_halvorsen = {
        en = "Halvorsen attractor",
    },
    opt_proc_chen = {
        en = "Chen attractor",
    },
    opt_proc_rabinovich = {
        en = "Rabinovich-Fabrikant attractor",
    },
    opt_proc_chua = {
        en = "Chua double-scroll",
    },
    opt_proc_rikitake = {
        en = "Rikitake dynamo attractor",
    },
    opt_proc_nose_hoover = {
        en = "Nosé-Hoover oscillator",
    },
    opt_proc_duffing = {
        en = "Forced Duffing oscillator",
    },
    opt_proc_de_jong = {
        en = "Peter de Jong map (delay embedding)",
    },
    opt_proc_clifford_map = {
        en = "Clifford map (delay embedding)",
    },
    opt_proc_ikeda = {
        en = "Ikeda map (delay embedding)",
    },
    opt_proc_trefoil = {
        en = "Trefoil knot",
    },
    opt_proc_torus_knot = {
        en = "(3,7) torus knot",
    },
    opt_proc_lissajous = {
        en = "3D Lissajous knot",
    },
    opt_proc_hopf_links = {
        en = "Hopf-link fibre bundle",
    },
    opt_proc_mobius = {
        en = "Möbius strip wireframe",
    },
    opt_proc_klein = {
        en = "Klein bottle immersion",
    },
    opt_proc_clifford_torus = {
        en = "Stereographic Clifford torus",
    },
    opt_proc_spherical_harmonic = {
        en = "Spherical harmonic Y(5,3) cage",
    },
    opt_proc_enneper = {
        en = "Enneper minimal surface",
    },
    opt_proc_helicoid = {
        en = "Helicoid minimal surface",
    },
    opt_proc_catenoid = {
        en = "Catenoid minimal surface",
    },
    opt_proc_roman = {
        en = "Steiner Roman surface",
    },
    opt_proc_superformula = {
        en = "Gielis superformula surface",
    },
    opt_proc_gyroid_contours = {
        en = "Gyroid implicit-surface contours",
    },
    opt_proc_fibonacci_sphere = {
        en = "Fibonacci sphere spiral",
    },
    opt_proc_sierpinski_tetra = {
        en = "Sierpiński tetrahedron",
    },
    opt_proc_abc_flow = {
        en = "ABC chaotic flow streamlines",
    },

    nav_geodesic_group = {
        en = "{#color(70,220,255)}Geodesic Heat Waves: navmesh contours{#reset()}",
    },
    nav_radius = {
        en = "Navmesh solve radius (m)",
    },
    nav_speed = {
        en = "Contour speed (m/s)",
    },
    nav_trails = {
        en = "Trailing contours",
    },
    nav_trail_spacing = {
        en = "Contour spacing (m)",
    },
    nav_surface_lift = {
        en = "Contour surface lift (m)",
    },
    nav_color = {
        en = "Contour color",
    },
    nav_loop = {
        en = "Loop geodesic pulse",
    },

    opt_heat_cyan = {
        en = "{#color(70,220,255)}Cyan{#reset()}",
    },
    opt_heat_amber = {
        en = "{#color(255,180,45)}Amber{#reset()}",
    },
    opt_heat_white = {
        en = "{#color(230,230,230)}White{#reset()}",
    },
    opt_heat_toxin = {
        en = "{#color(90,235,110)}Toxin{#reset()}",
    },

    opt_scheme_classic = {
        en = "Classic",
    },
    opt_scheme_mono = {
        en = "Monochrome",
    },
    opt_scheme_infrared = {
        en = "Infrared",
    },
    opt_scheme_amber = {
        en = "Amber",
    },
    opt_scheme_toxin = {
        en = "Toxin",
    },
    opt_scheme_rainbow = {
        en = "Rainbow",
    },
    opt_one_line = {
        en = "1",
    },
    opt_two_lines = {
        en = "2",
    },
    opt_three_lines = {
        en = "3",
    },
}
