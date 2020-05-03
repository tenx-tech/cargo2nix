#![forbid(unsafe_code)]

use std::{
    borrow::Cow,
    collections::{BTreeMap, BTreeSet, HashMap},
    fs,
    io::{self, BufRead, Write},
    path::Path,
};

use anyhow::{anyhow, Context, Result};
use cargo::{
    core::{
        compiler::{CompileKind, RustcTargetData},
        dependency::DepKind,
        resolver::{features::HasDevUnits, Resolve, ResolveOpts},
        Package, PackageId, PackageIdSpec, Workspace,
    },
    ops::{resolve_ws_with_opts, Packages},
    util::important_paths::find_root_manifest_for_wd,
};
use cargo_platform::Platform;
use colorify::colorify;
use semver::{Version, VersionReq};
use tera::Tera;

use crate::expr::BoolExpr;
use crate::template::BuildPlan;

mod expr;
mod manifest;
mod platform;
mod template;

type Feature<'a> = &'a str;
type PackageName<'a> = &'a str;
type RootFeature<'a> = (PackageName<'a>, Feature<'a>);

const VERSION_ATTRIBUTE_NAME: &str = "cargo2nixVersion";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let args: Vec<&str> = args.iter().map(AsRef::as_ref).collect();
    if let Err(err) = try_main(&args) {
        eprint!(colorify!(red_bold: "error: "));
        eprintln!("{:#}", &err);
        std::process::exit(1);
    }
}

fn try_main(args: &[&str]) -> Result<()> {
    match &args[1..] {
        ["--stdout"] | ["-s"] => generate_cargo_nix(io::stdout().lock()),
        ["--file"] | ["-f"] => write_to_file("Cargo.nix"),
        ["--file", file] | ["-f", file] => write_to_file(file),
        ["--help"] | ["-h"] => print_help(),
        ["--version"] | ["-v"] => {
            println!("{}", version());
            Ok(())
        }
        [] => print_help(),
        _ => {
            println!("Invalid arguments: {:?}", &args[1..]);
            println!("\nTry again, with help: \n");
            print_help()
        }
    }
}

fn version() -> Version {
    // Since `CARGO_PKG_VERSION` is provided by Cargo itself, which uses the same `semver` crate to
    // parse version strings, the `unwrap()` below should never fail.
    Version::parse(env!("CARGO_PKG_VERSION")).unwrap()
}

fn read_version_attribute(path: &Path) -> Result<Version> {
    let file = fs::File::open(path).context(format!("Couldn't open file {}", path.display()))?;
    io::BufReader::new(file)
        .lines()
        .filter_map(|line| line.ok())
        .find(|line| line.trim_start().starts_with(VERSION_ATTRIBUTE_NAME))
        .and_then(|s| {
            if let Some(i) = s.find('"') {
                if let Some(j) = s.rfind('"') {
                    return Version::parse(&s[i + 1..j]).ok();
                }
            }
            None
        })
        .ok_or(anyhow!(
            "valid {} not found in {}",
            VERSION_ATTRIBUTE_NAME,
            path.display()
        ))
}

fn version_req(path: &Path) -> Result<(VersionReq, Version)> {
    let version = read_version_attribute(path)?;
    let req = format!(">={}.{}", version.major, version.minor);
    VersionReq::parse(&req)
        .context(format!("parse {} found in {}", req, path.display()))
        .map_err(anyhow::Error::from)
        .map(|req| (req, version))
}

fn print_help() -> Result<()> {
    println!("cargo2nix-{}\n", version());
    println!("$ cargo2nix                        # Print the help");
    println!("$ cargo2nix -s,--stdout            # Output to stdout");
    println!("$ cargo2nix -f,--file              # Output to Cargo.nix");
    println!("$ cargo2nix -f,--file <file>       # Output to the given file");
    println!("$ cargo2nix -v,--version           # Print version of cargo2nix");
    println!("$ cargo2nix -h,--help              # Print the help");
    Ok(())
}

fn write_to_file(file: impl AsRef<Path>) -> Result<()> {
    let path = file.as_ref();
    if path.exists() {
        let (vers_req, ver) = version_req(path)?;
        if !vers_req.matches(&version()) {
            let mut message = format!(
                colorify!(red_bold: "Version requirement {} [{}]\n"),
                vers_req, ver
            );
            message.push_str(&format!(
                colorify!(red: "Your cargo2nix version is {}, whereas the file '{}' was generated by a newer version of cargo2nix.\n"),
                version(),
                path.display()
            ));
            message.push_str(&format!(
                colorify!(red: "Please upgrade your cargo2nix ({}) to proceed."),
                vers_req
            ));
            return Err(anyhow!("{}", message));
        }

        println!(
            colorify!(green_bold: "Version {} matches the requirement {} [{}]"),
            version(),
            vers_req,
            ver
        );
        print!(
            "warning: do you want to overwrite '{}'? yes/no: ",
            path.display()
        );

        io::stdout().flush()?;
        let mut line = String::new();
        io::stdin().read_line(&mut line)?;
        if line.trim() != "yes" {
            println!("aborted!");
            return Ok(());
        }
    }

    let mut temp_file = tempfile::Builder::new()
        .tempfile()
        .context("could not create new temporary file")?;

    generate_cargo_nix(&mut temp_file)?;

    if let Err(err) = temp_file.persist(path) {
        let (_, temp_path) = err.file.keep()?;
        std::fs::copy(temp_path, path)
            .context(format!("could not write file to {}", path.display()))?;
    }

    Ok(())
}

fn generate_cargo_nix(mut out: impl io::Write) -> Result<()> {
    let config = {
        let mut config = cargo::Config::default()?;
        config.configure(0, true, None, false, true, false, &None, &[], &[])?;
        config
    };

    let root_manifest_path = find_root_manifest_for_wd(config.cwd())?;
    let ws = Workspace::new(&root_manifest_path, &config)?;
    let rtd = RustcTargetData::new(&ws, CompileKind::Host)?;
    let specs = Packages::All.to_package_id_specs(&ws)?;
    let resolve = resolve_ws_with_opts(
        &ws,
        &rtd,
        CompileKind::Host,
        &ResolveOpts::everything(),
        &specs,
        HasDevUnits::Yes,
    )?;

    let pkgs_by_id = resolve
        .pkg_set
        .get_many(resolve.pkg_set.package_ids())?
        .iter()
        .map(|pkg| (pkg.package_id(), *pkg))
        .collect();

    let mut rpkgs_by_id = resolve
        .pkg_set
        .get_many(resolve.pkg_set.package_ids())?
        .iter()
        .map(|pkg| {
            ResolvedPackage::new(pkg, &pkgs_by_id, &resolve.targeted_resolve)
                .map(|res| (pkg.package_id(), res))
        })
        .collect::<Result<_>>()?;

    let root_pkgs: Vec<_> = ws.members().collect();
    for pkg in root_pkgs.iter() {
        let pkg_ws = Workspace::new(pkg.manifest_path(), &config)?;
        mark_required(pkg, &pkg_ws, &mut rpkgs_by_id)?;
        for feature in all_features(&pkg) {
            activate(pkg, feature, &pkg_ws, &mut rpkgs_by_id)?;
        }
    }

    simplify_optionality(rpkgs_by_id.values_mut(), root_pkgs.len());
    let root_manifest = fs::read(&root_manifest_path)?;
    let profiles = manifest::extract_profiles(&root_manifest);

    let plan = BuildPlan::from_items(root_pkgs, profiles, rpkgs_by_id, config.cwd())?;
    let mut tera = Tera::default();
    tera.add_raw_template(
        "Cargo.nix.tera",
        include_str!("../templates/Cargo.nix.tera"),
    )?;
    let context = tera::Context::from_serialize(plan)?;
    let rendered = tera.render("Cargo.nix.tera", &context)?;
    write!(out, "{}", rendered)?;

    Ok(())
}

fn simplify_optionality<'a, 'b: 'a>(
    rpkgs: impl IntoIterator<Item = &'a mut ResolvedPackage<'b>>,
    n_root_pkgs: usize,
) {
    for rpkg in rpkgs.into_iter() {
        for optionality in rpkg.iter_optionality_mut() {
            if let Optionality::Optional {
                ref required_by_pkgs,
                ..
            } = optionality
            {
                if required_by_pkgs.len() == n_root_pkgs {
                    // This dependency/feature of this package is required by any of the root packages.
                    *optionality = Optionality::Required;
                }
            }
        }

        // Dev dependencies can't be optional.
        rpkg.deps
            .iter_mut()
            .filter(|((_, kind), _)| *kind == DepKind::Development)
            .for_each(|(_, d)| d.optionality = Optionality::Required);

        if all_eq(rpkg.iter_optionality_mut()) {
            // This package is always required by a subset of the root packages with the same set of features.
            rpkg.iter_optionality_mut()
                .for_each(|o| *o = Optionality::Required);
        }
    }
}

fn all_features(pkg: &Package) -> impl Iterator<Item = Feature> + '_ {
    let features = pkg.summary().features();
    features
        .keys()
        .map(|k| k.as_str())
        .chain(
            pkg.dependencies()
                .iter()
                .filter(|d| d.is_optional())
                .map(|d| d.name_in_toml().as_str()),
        )
        .chain(if features.contains_key("default") {
            None
        } else {
            Some("default")
        })
}

fn is_proc_macro(pkg: &Package) -> bool {
    use cargo::core::{LibKind, TargetKind};
    pkg.targets()
        .iter()
        .filter_map(|t| match t.kind() {
            TargetKind::Lib(kinds) => Some(kinds.iter()),
            _ => None,
        })
        .flatten()
        .any(|k| *k == LibKind::ProcMacro)
}

/// Traverses the whole dependency graph starting at `pkg` and marks required packages and features.
fn mark_required(
    root_pkg: &Package,
    ws: &Workspace,
    rpkgs_by_id: &mut BTreeMap<PackageId, ResolvedPackage>,
) -> Result<()> {
    let spec = PackageIdSpec::from_package_id(root_pkg.package_id());
    let rtd = RustcTargetData::new(&ws, CompileKind::Host)?;
    let resolve = resolve_ws_with_opts(
        ws,
        &rtd,
        CompileKind::Host,
        &ResolveOpts::new(true, &[], false, false),
        &[spec],
        HasDevUnits::Yes,
    )?;

    let root_pkg_name = root_pkg.name().as_str();
    // Dependencies that are activated, even when no features are activated, must be required.
    for id in resolve.targeted_resolve.iter() {
        let rpkg = rpkgs_by_id.get_mut(&id).unwrap();
        for feature in resolve.targeted_resolve.features(id).iter() {
            rpkg.features
                .get_mut(feature.as_str())
                .unwrap()
                .required_by(root_pkg_name);
        }

        for (dep_id, _) in resolve.targeted_resolve.deps(id) {
            for dep in rpkg.iter_deps_with_id_mut(dep_id) {
                dep.optionality.required_by(root_pkg_name);
            }
        }
    }

    Ok(())
}

fn activate<'a>(
    pkg: &'a Package,
    feature: Feature<'a>,
    ws: &Workspace,
    rpkgs_by_id: &mut BTreeMap<PackageId, ResolvedPackage<'a>>,
) -> Result<()> {
    let spec = PackageIdSpec::from_package_id(pkg.package_id());
    let (features, uses_default) = match feature {
        "default" => (vec![], true),
        other => (vec![other.to_string()], false),
    };
    let rtd = RustcTargetData::new(&ws, CompileKind::Host)?;
    let resolve = resolve_ws_with_opts(
        ws,
        &rtd,
        CompileKind::Host,
        &ResolveOpts::new(true, &features[..], false, uses_default),
        &[spec],
        HasDevUnits::Yes,
    )?;

    let root_feature = (pkg.name().as_str(), feature);
    for id in resolve.targeted_resolve.iter() {
        let rpkg = rpkgs_by_id.get_mut(&id).unwrap();
        for feature in resolve.targeted_resolve.features(id).iter() {
            rpkg.features
                .get_mut(feature.as_str())
                .unwrap()
                .activated_by(root_feature);
        }

        for (dep_id, _) in resolve.targeted_resolve.deps(id) {
            for dep in rpkg.iter_deps_with_id_mut(dep_id) {
                dep.optionality.activated_by(root_feature)
            }
        }
    }

    Ok(())
}

#[derive(Debug)]
pub struct ResolvedPackage<'a> {
    pkg: &'a Package,
    deps: BTreeMap<(PackageId, DepKind), ResolvedDependency<'a>>,
    features: BTreeMap<Feature<'a>, Optionality<'a>>,
    checksum: Option<Cow<'a, str>>,
}

impl<'a> ResolvedPackage<'a> {
    fn new(
        pkg: &'a Package,
        pkgs_by_id: &HashMap<PackageId, &'a Package>,
        resolve: &'a Resolve,
    ) -> Result<Self> {
        let mut deps = BTreeMap::new();
        resolve
            .deps(pkg.package_id())
            .filter_map(|(dep_id, deps)| {
                let dep_pkg = pkgs_by_id[&dep_id];
                let extern_name = resolve
                    .extern_crate_name(
                        pkg.package_id(),
                        dep_id,
                        dep_pkg.targets().iter().find(|t| t.is_lib())?,
                    )
                    .ok()?;

                Some(
                    deps.iter()
                        .map(move |dep| (dep_id, dep, dep_pkg, extern_name.clone())),
                )
            })
            .flatten()
            .for_each(|(dep_id, dep, dep_pkg, extern_name)| {
                let rdep = deps
                    .entry((dep_id, dep.kind()))
                    .or_insert(ResolvedDependency {
                        extern_name,
                        pkg: dep_pkg,
                        optionality: Optionality::default(),
                        platforms: Some(Vec::new()),
                    });

                match (dep.platform(), rdep.platforms.as_mut()) {
                    (Some(platform), Some(platforms)) => platforms.push(platform),
                    (None, _) => rdep.platforms = None,
                    _ => {}
                }
            });

        let features = resolve
            .features(pkg.package_id())
            .iter()
            .map(|feature| (feature.as_str(), Optionality::default()))
            .collect();

        let checksum = {
            let checksum = resolve
                .checksums()
                .get(&pkg.package_id())
                .and_then(|s| s.as_ref().map(Cow::from));

            let source_id = pkg.package_id().source_id();
            if checksum.is_none() && source_id.is_git() {
                let url = source_id.url().as_str();
                let rev = source_id
                    .precise()
                    .ok_or(anyhow!("no precise git reference for {}", pkg.package_id()))?;
                prefetch_git(url, rev)
                    .map(Cow::Owned)
                    .map(Some)
                    .context(format!(
                        "failed to compute SHA256 for {} using nix-prefetch-git",
                        pkg.package_id(),
                    ))?
            } else {
                checksum
            }
        };

        Ok(Self {
            pkg,
            deps,
            features,
            checksum,
        })
    }

    fn iter_deps_with_id_mut(
        &mut self,
        id: PackageId,
    ) -> impl Iterator<Item = &mut ResolvedDependency<'a>> {
        self.deps
            .range_mut((id, DepKind::Normal)..=(id, DepKind::Build))
            .map(|(_, dep)| dep)
    }

    fn iter_optionality_mut(&mut self) -> impl Iterator<Item = &mut Optionality<'a>> {
        self.deps
            .iter_mut()
            .filter(|((_, kind), _)| *kind != DepKind::Development)
            .map(|(_, d)| &mut d.optionality)
            .chain(self.features.values_mut())
    }
}

#[derive(Debug)]
struct ResolvedDependency<'a> {
    extern_name: String,
    pkg: &'a Package,
    optionality: Optionality<'a>,
    platforms: Option<Vec<&'a Platform>>,
}

#[derive(PartialEq, Eq, Debug)]
enum Optionality<'a> {
    Required,
    Optional {
        required_by_pkgs: BTreeSet<PackageName<'a>>,
        activated_by_features: BTreeSet<RootFeature<'a>>,
    },
}

impl<'a> Default for Optionality<'a> {
    fn default() -> Self {
        Optionality::Optional {
            required_by_pkgs: Default::default(),
            activated_by_features: Default::default(),
        }
    }
}

impl<'a> Optionality<'a> {
    fn activated_by(&mut self, (pkg_name, feature): RootFeature<'a>) {
        if let Optionality::Optional {
            required_by_pkgs,
            activated_by_features,
        } = self
        {
            if !required_by_pkgs.contains(pkg_name) {
                activated_by_features.insert((pkg_name, feature));
            }
        }
    }

    fn required_by(&mut self, pkg_name: PackageName<'a>) {
        if let Optionality::Optional {
            required_by_pkgs, ..
        } = self
        {
            required_by_pkgs.insert(pkg_name);
        }
    }

    fn to_expr(&self, root_features_var: &str) -> BoolExpr {
        use self::BoolExpr::*;

        match self {
            Optionality::Required => True,
            Optionality::Optional {
                activated_by_features,
                required_by_pkgs,
            } => {
                BoolExpr::ors(
                    activated_by_features
                        .iter()
                        .map(|root_feature| {
                            Single(format!(
                                "{} ? {:?}",
                                root_features_var,
                                display_root_feature(*root_feature)
                            ))
                        })
                        .chain(required_by_pkgs.iter().map(|pkg_name| {
                            Single(format!("{} ? {:?}", root_features_var, pkg_name))
                        })),
                )
            }
        }
    }
}

fn display_root_feature((pkg_name, feature): RootFeature) -> String {
    format!("{}/{}", pkg_name, feature)
}

fn prefetch_git(url: &str, rev: &str) -> Result<String> {
    use std::process::{Command, Output};

    let Output {
        stdout,
        stderr,
        status,
    } = Command::new("nix-prefetch-git")
        .arg("--quiet")
        .args(&["--url", url])
        .args(&["--rev", rev])
        .output()?;

    if status.success() {
        serde_json::from_slice::<serde_json::Value>(&stdout)?
            .get("sha256")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .ok_or(anyhow!("unexpected JSON output"))
    } else {
        Err(anyhow!(
            "process failed with stderr {:?}",
            String::from_utf8(stderr)
        ))
    }
}

fn all_eq<T, I>(i: I) -> bool
where
    I: IntoIterator<Item = T>,
    T: PartialEq,
{
    let mut iter = i.into_iter();
    let first = match iter.next() {
        Some(x) => x,
        None => return true,
    };

    iter.all(|x| x == first)
}
