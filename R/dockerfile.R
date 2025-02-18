# Copyright 2018 Opening Reproducible Research (https://o2r.info)

#' dockerfile-method
#'^
#' Create a Dockerfile based on either a sessionInfo, a workspace or a file.
#'
#' @section Based on \code{sessionInfo}:
#'
#' Use the current \code{\link[utils]{sessionInfo})} to create a Dockerfile.
#'
#' @section Based on a workspace/directory:
#'
#' Given an existing path to a directory, the method tries to automatically find the main \code{R} file within that directory.
#' Files are searched recursively. The following types are supported:
#'
#' \enumerate{
#'   \item regular R script files, identified by file names ending in \code{.R}
#'   \item weaved documents, identified by file names ending in \href{http://rmarkdown.rstudio.com/}{R Markdown} (\code{.Rmd})
#' }
#'
#' After identifying the main file, the process continues as described in the section file.
#' If both types are found, documents are given priority over scripts.
#' If multiple files are found, the first file as returned by \code{\link[base]{dir}} will be used.
#'
#' @section Based on a file:
#'
#' Given an executable \code{R} script or document, create a Dockerfile to execute this file.
#' This executes the whole file to obtain a complete \code{sessionInfo} object, see section "Based on \code{sessionInfo}", and copies required files and documents into the container.
#'
#' @param from The source of the information to construct the Dockerfile. Can be a \code{sessionInfo} object, a path to a file within the working direcotry, a \code{DESCRIPTION} file, or the path to a workspace). If \code{NULL} then no automatic derivation of dependencies happens. If a \code{DESCRIPTION} file, then the minimum R version (e.g. "R (3.3.0)") is used for the image version and all "Imports" are explicitly installed; the package from the \code{DESCRIPTION} itself is only .
#' @param image (\linkS4class{From}-object or character) Specifes the image that shall be used for the Docker container (\code{FROM} instruction).
#'      By default, the image selection is based on the given session. Alternatively, use \code{getImageForVersion(..)} to get an existing image for a manually defined version of R, matching the version with tags from the base image rocker/r-ver (see details about the rocker/r-ver at \url{https://hub.docker.com/r/rocker/r-ver/}). Or provide a correct image name yourself.
#' @param maintainer Specify the maintainer of the Dockerfile. See documentation at \url{https://docs.docker.com/engine/reference/builder/#maintainer}. Defaults to \code{Sys.info()[["user"]]}. Can be removed with \code{NULL}.
#' @param save_image When TRUE, it calls \link[base]{save.image} in the current working directory and copys the resulting \code{.RData} file to the container's working directory. The created file in the local working director will not be deleted.
#'  Alternatively, you can pass a list of objects to be saved, which may also include arguments to be passed down to \code{save}, e.g. \code{save_image = list("object1", "object2")}. You can configure the name of the file the objects are saved to by adding a file name to the list of arguments, e.g. \code{save_image = list("objectA", save_image_filename = "mydata.RData")}, in which case the file path must be in UNIX notation. Note that you may not use \code{save_image_filename} for other objects in your session!
#' \code{save} will be called with \code{envir}.
#' @param envir The environment for \code{save_image}.
#' @param env optionally specify environment variables to be included in the image. See documentation: \url{https://docs.docker.com/engine/reference/builder/#env}
#' @param soft (boolean) Whether to include soft dependencies when system dependencies are installed, default is no.
#' @param offline (boolean) Whether to use an online database to detect system dependencies or use local package information (slower!), default is no.
#' @param copy whether and how a workspace should be copied; allowed values: "script", "script_dir" (paths relative to file, so only works for file-base \code{from} inputs, which (can be nested) within current working directory), a list of file paths relative to the current working directory to be copied into the payload directory, or \code{NULL} to disable copying of files
#' @param container_workdir the working directory in the container, defaults to \code{/payload/} and must end with \code{/}. Can be skipped with value \code{NULL}.
#' @param cmd The CMD statement that should be executed by default when running a parameter. Use \code{CMD_Rscript(path)} in order to reference an R script to be executed on startup, \code{CMD_Render(path)} to render an R Markdown document, or \code{Cmd(command)} for any command. If \code{character} is provided it is passed wrapped in a \code{Cmd(command)}.
#' @param entrypoint the ENTRYPOINT statement for the Dockerfile
#' @param add_self Whether to add the package containerit itself if loaded/attached to the session
#' @param add_loadedOnly Whether to add the 'loadedOnly' packages if a sessionInfo is provided
#' @param silent Whether or not to print information during execution
#' @param predetect Extract the required libraries based on \code{library} calls using the package \code{automagic} before running a script/document
#' @param versioned_libs [EXPERIMENTAL] Whether it shall be attempted to match versions of linked external libraries
#' @param versioned_packages Whether it shall be attempted to match versions of R packages
#' @param filter_baseimage_pkgs Do not add packages from CRAN that are already installed in the base image. This does not apply to non-CRAN dependencies, e.g. packages install from GitHub, and does not check the package version.
#'
#' @return An object of class Dockerfile
#'
#' @export
#'
#' @import futile.logger
#' @importFrom utils capture.output
#' @importFrom stringr str_detect regex str_extract str_length str_sub
#' @importFrom desc desc
#' @importFrom fs dir_exists
#'
#' @examples
#' dockerfile <- dockerfile()
#' print(dockerfile)
#'
dockerfile <- function(from = utils::sessionInfo(),
                       image = getImageForVersion(getRVersionTag(from)),
                       maintainer = Sys.info()[["user"]],
                       save_image = FALSE,
                       envir = .GlobalEnv,
                       env = list(generator = paste("containerit", utils::packageVersion("containerit"))),
                       soft = FALSE,
                       offline = FALSE,
                       copy = NULL,
                       # nolint start
                       container_workdir = "/payload/",
                       # nolint end
                       cmd = "R",
                       entrypoint = NULL,
                       add_self = FALSE,
                       add_loadedOnly = FALSE,
                       silent = FALSE,
                       predetect = TRUE,
                       versioned_libs = FALSE,
                       versioned_packages = FALSE,
                       filter_baseimage_pkgs = FALSE,
                       ...) {
    if (silent) {
      invisible(futile.logger::flog.threshold(futile.logger::WARN))
    }

  if (grepl("renv.lock", from)) {
    dock <- dockerfiler::dock_from_renv(from, ...)
    return(dock)
  }

    the_dockerfile <- NA
    originalFrom <- class(from)

    #parse From-object from string if necessary
    if (is.character(image)) {
      image <- parseFrom(image)
    }

    futile.logger::flog.debug("Creating a new Dockerfile from object of class '%s' with base image %s", class(from), toString(image))

    if (is.character(maintainer)) {
      .label <- Label_Maintainer(maintainer)
      futile.logger::flog.debug("Turning maintainer character string '%s' into label: %s", maintainer, toString(.label))
      maintainer <- .label
    }

    # create/check CMD instruction
    if (is.character(cmd)) {
      command <- Cmd(cmd)
      futile.logger::flog.debug("Turned cmd character string '%s' into command: %s", cmd, toString(command))
    } else {
      command <- cmd
    }
    if (!inherits(x = command, "Cmd")) {
      stop("Unsupported parameter for 'cmd', expected an object of class 'Cmd', given was :", class(command))
    }

    # check ENTRYPOINT instruction
    if ( !is.null(entrypoint) && !inherits(x = entrypoint, "Entrypoint")) {
      stop("Unsupported parameter for 'entrypoint', expected an object of class 'Entrypoint', given was :",
        class(entrypoint))
    }

    # check and create WORKDIR instruction
    workdir <- NULL
    if ( !is.null(container_workdir)) {
      if ( !is.character(container_workdir)) {
        stop("Unsupported parameter for 'container_workdir', expected a character string or NULL")
      } else {
        workdir <- Workdir(container_workdir)
      }
    }

    # check whether image is supported
    image_name <- image@image
    if (!image_name %in% .supported_images) {
      warning("Unsupported base image. Proceed at your own risk. The following base images are supported:\n",
        paste(.supported_images, collapse = "\n"))
    }

    # base dockerfile
    the_dockerfile <- methods::new("Dockerfile",
                                instructions = list(),
                                maintainer = maintainer,
                                image = image,
                                entrypoint = entrypoint,
                                cmd = command)

    # handle different "from" cases
    if (is.null(from)) {
      futile.logger::flog.debug("from is NULL, not deriving any information at all")
      if (!is.null(workdir))
        addInstruction(the_dockerfile) <- workdir
    } else if (inherits(from, "expression")
               || (is.list(from) && all(sapply(from, is.expression))) ) {
      futile.logger::flog.debug("Creating from expression object with a clean session %s", toString(from))
      the_session <- clean_session(expr = from,
                               predetect = predetect,
                               echo = !silent)
      the_dockerfile <- dockerfileFromSession(session = the_session,
                                              base_dockerfile = the_dockerfile,
                                              soft,
                                              offline,
                                              add_self,
                                              add_loadedOnly,
                                              versioned_libs,
                                              versioned_packages,
                                              filter_baseimage_pkgs,
                                              workdir)
    } else if (is.data.frame(x = from)) {
      futile.logger::flog.debug("Creating from data.frame with names (need: name, version, source), ", names(x))
      the_dockerfile <- dockerfileFromPackages(pkgs = from,
                                               base_dockerfile = the_dockerfile,
                                               soft,
                                               offline,
                                               versioned_libs,
                                               versioned_packages,
                                               filter_baseimage_pkgs,
                                               workdir)
    } else if (inherits(x = from, "sessionInfo")) {
      futile.logger::flog.debug("Creating from sessionInfo object")
      the_dockerfile <- dockerfileFromSession(session = from,
                                              base_dockerfile = the_dockerfile,
                                              soft,
                                              offline,
                                              add_self,
                                              add_loadedOnly,
                                              versioned_libs,
                                              versioned_packages,
                                              filter_baseimage_pkgs,
                                              workdir)
    } else if (inherits(x = from, "description")) {
      futile.logger::flog.debug("Creating from description object")
      the_dockerfile <- dockerfileFromDescription(description = from,
                                                  base_dockerfile = the_dockerfile,
                                                  soft,
                                                  copy,
                                                  offline,
                                                  versioned_libs,
                                                  versioned_packages,
                                                  filter_baseimage_pkgs,
                                                  workdir)
    } else if (inherits(x = from, "character")) {
      futile.logger::flog.debug("Creating from character string '%s'", from)
      originalFrom <- from

      if (fs::dir_exists(from)) {
        futile.logger::flog.debug("'%s' is a directory", from)
        the_dockerfile <- dockerfileFromWorkspace(path = from,
                                                  base_dockerfile = the_dockerfile,
                                                  soft,
                                                  copy,
                                                  offline,
                                                  add_self,
                                                  add_loadedOnly,
                                                  silent,
                                                  predetect,
                                                  versioned_libs,
                                                  versioned_packages,
                                                  filter_baseimage_pkgs,
                                                  workdir)
      } else if (file.exists(from)) {
        futile.logger::flog.debug("'%s' is a file", from)

        if (basename(from) == "DESCRIPTION") {
          description <- desc::desc(file = from)
          the_dockerfile <- dockerfileFromDescription(description = description,
                                                      base_dockerfile = the_dockerfile,
                                                      soft,
                                                      copy,
                                                      offline,
                                                      versioned_libs,
                                                      versioned_packages,
                                                      filter_baseimage_pkgs,
                                                      workdir)
        } else {
          the_dockerfile <- dockerfileFromFile(fromFile = from,
                                               base_dockerfile = the_dockerfile,
                                               soft,
                                               copy,
                                               offline,
                                               add_self,
                                               add_loadedOnly,
                                               silent,
                                               predetect,
                                               versioned_libs,
                                               versioned_packages,
                                               filter_baseimage_pkgs,
                                               workdir)
        }
      } else {
        stop("Unsupported string for 'from' argument (not a file, not a directory): ", from)
      }
    } else {
      stop("Unsupported 'from': ", class(from), " ", from)
    }

    # copy additional objects into the container in an RData file
    .filename = ".RData"
    if ("save_image_filename" %in% names(save_image)) {
      .filename <- save_image$save_image_filename
    }
    if (isTRUE(save_image)) {
      futile.logger::flog.debug("Saving image to file %s with %s and adding COPY instruction using environment %s",
                                .filename, toString(ls(envir = envir)),
                                utils::capture.output(envir))
      save(list = ls(envir = envir), file = .filename, envir = envir)
      addInstruction(the_dockerfile) <- Copy(src = .filename, dest = .filename)
    } else if (is.list(save_image)) {
      futile.logger::flog.debug("Saving image to file %s and adding COPY instruction based on %s",
                                .filename, toString(save_image))
      save(list = unlist(save_image[names(save_image) != "save_image_filename"]), file = .filename, envir = envir)
      addInstruction(the_dockerfile) <- Copy(src = .filename, dest = .filename)
    }

    futile.logger::flog.info("Created Dockerfile-Object based on %s", originalFrom)
    return(the_dockerfile)
}

dockerfileFromPackages <- function(pkgs,
                                   base_dockerfile,
                                   soft,
                                   offline,
                                   versioned_libs,
                                   versioned_packages,
                                   filter_baseimage_pkgs,
                                   workdir) {
  futile.logger::flog.debug("Creating from packages data.frame")

  # The platform is determined only for known images.
  # Alternatively, we could let the user optionally specify one amongst different supported platforms
  platform = NULL
  image_name = base_dockerfile@image@image
  if (image_name %in% .debian_images) {
    platform = .debian_platform
    futile.logger::flog.debug("Found image %s in list of Debian images", image_name)
  }
  futile.logger::flog.debug("Detected platform: %s", platform)

  the_dockerfile <- add_install_instructions(base_dockerfile,
                                             pkgs,
                                             platform,
                                             soft,
                                             offline,
                                             versioned_libs,
                                             versioned_packages,
                                             filter_baseimage_pkgs)

  # after all installation is done, set the workdir
  if (!is.null(workdir))
    addInstruction(the_dockerfile) <- workdir

  return(the_dockerfile)
}

dockerfileFromSession <- function(session, ...) {
  UseMethod("dockerfileFromSession", session)
}

dockerfileFromSession.sessionInfo <- function(session,
                                              base_dockerfile,
                                              soft,
                                              offline,
                                              add_self,
                                              add_loadedOnly,
                                              versioned_libs,
                                              versioned_packages,
                                              filter_baseimage_pkgs,
                                              workdir) {
  futile.logger::flog.debug("Creating from sessionInfo")

  pkgs <- session$otherPkgs
  if (add_loadedOnly) {
    futile.logger::flog.debug("Adding 'loadedOnly' packages")
    pkgs <- append(pkgs, session$loadedOnly)
  }

  if (!add_self && !is.null(pkgs$containerit)) {
    futile.logger::flog.debug("Removing self from the list of packages")
    pkgs$containerit <- NULL
  }

  # 1. identify where to install the package from
  pkgs_list <- lapply(pkgs, function(pkg) {
           #determine package name
           if ("Package" %in% names(pkg))
             name <- pkg$Package
           else
             stop("Package name cannot be determined for ", pkg)

           if ("Priority" %in% names(pkg) &&
               stringr::str_detect(pkg$Priority, "(?i)base")) {
             futile.logger::flog.debug("Skipping Priority package %s, is included with R", name)
             return(NULL)
           } else {
             version <- NA
             source <- NA

             #check if package come from CRAN, GitHub or Bioconductor
             if ("Repository" %in% names(pkg) &&
                 stringr::str_detect(pkg$Repository, "(?i)CRAN")) {
               source <- "CRAN"
               version <- pkg$Version
             } else if ("RemoteType" %in% names(pkg) &&
                        stringr::str_detect(pkg$RemoteType, "(?i)github")) {
               source <- "github"
               version <- getGitHubRef(name, pkgs)
             } else if ("biocViews" %in% names(pkg)) {
               source <- "Bioconductor"
               version <- pkg$Version
             } else {
               warning("Failed to identify a source for package ", name,
                       ". Therefore the package cannot be installed in the Docker image.\n")
               return(NULL)
             }

             return(list(name = name, version = version, source = source))
           }
         })

  # remove NULLs
  pkgs_list <- pkgs_list[!vapply(pkgs_list, is.null, logical(1))]

  packages_df <- do.call("rbind", lapply(pkgs_list, as.data.frame))
  futile.logger::flog.debug("Found %s packages in sessionInfo", nrow(packages_df))
  futile.logger::flog.debug("Did not add packages because no source or included in base:",
                            toString(names(pkgs)[!((names(pkgs) %in% packages_df$name))]))

  the_dockerfile <- dockerfileFromPackages(pkgs = packages_df,
                                           base_dockerfile,
                                           soft,
                                           offline,
                                           versioned_libs,
                                           versioned_packages,
                                           filter_baseimage_pkgs,
                                           workdir)
  return(the_dockerfile)
}

dockerfileFromSession.session_info <- function(session,
                                               base_dockerfile,
                                               soft,
                                               offline,
                                               add_self,
                                               add_loadedOnly,
                                               versioned_libs,
                                               versioned_packages,
                                               filter_baseimage_pkgs,
                                               workdir) {
  futile.logger::flog.debug("Creating from session_info")

  if (is.null(session$packages) || !(inherits(session$packages, "packages_info")))
    stop("Unsupported object of class session_info, needs list slot 'packages' of class 'packages_info'")

  packages_df <- as.data.frame(session$packages)[,c("package", "loadedversion", "source")]
  names(packages_df) <- c("name", "version", "source")

  if (!add_self) {
    futile.logger::flog.debug("Removing self from the list of packages")
    packages_df <- packages_df[packages_df$name != "containerit",]
  }

  # create version strings as we want them for GitHub packages
  pkgs_gh <- packages_df[stringr::str_detect(string = packages_df$source, stringr::regex("GitHub", ignore_case = TRUE)),]
  if (nrow(pkgs_gh) > 0) {
    for (pkg in pkgs_gh$name) {
      currentPkg <- subset(pkgs_gh, pkgs_gh$name == pkg)
      versionString <- stringr::str_extract(string = currentPkg$source, pattern = "(?<=\\()(.*)(?=\\))")
      packages_df[packages_df$name == pkg,c("version")] <- versionString
    }
  }

  the_dockerfile <- dockerfileFromPackages(pkgs = packages_df,
                                           base_dockerfile,
                                           soft,
                                           offline,
                                           versioned_libs,
                                           versioned_packages,
                                           filter_baseimage_pkgs,
                                           workdir)
  return(the_dockerfile)
}

#' @importFrom fs path_has_parent path_rel path_norm
dockerfileFromFile <- function(fromFile,
                               base_dockerfile,
                               soft,
                               copy,
                               offline,
                               add_self,
                               add_loadedOnly,
                               silent,
                               predetect,
                               versioned_libs,
                               versioned_packages,
                               filter_baseimage_pkgs,
                               workdir) {
    futile.logger::flog.debug("Creating from file ", fromFile)

    # prepare context ( = working directory) and normalize paths:
    context = fs::path_norm(getwd())
    if ( !fs::path_has_parent(fromFile, context))
      warning("The given file is not inside the working directory! This may lead to incorrect COPY instructions.")

    rel_file = fs::path_rel(fromFile, context)
    futile.logger::flog.debug("Working with file %s in working directory %s", rel_file, context)

    # execute script / markdowns or read RData file to obtain sessioninfo
    if (stringr::str_detect(string = rel_file,
                            pattern = stringr::regex(".R$", ignore_case = TRUE))) {
      futile.logger::flog.info("Processing R script file '%s' locally.", rel_file)
      sessionInfo <- clean_session(script_file = rel_file,
                                   echo = !silent,
                                   predetect = predetect)
    } else if (stringr::str_detect(string = rel_file,
                                   pattern = stringr::regex(".rmd$", ignore_case = TRUE))) {
      futile.logger::flog.info("Processing Rmd file '%s' locally using rmarkdown::render(...)", rel_file)
      sessionInfo <- clean_session(rmd_file = rel_file,
                                   echo = !silent,
                                   predetect = predetect)
    } else if (stringr::str_detect(string = rel_file,
                                   pattern = stringr::regex(".rdata$", ignore_case = TRUE))) {
      futile.logger::flog.info("Extracting session object from RData file %s", rel_file)
      sessionInfo <- extract_session_file(rel_file)
    } else{
      futile.logger::flog.info("The supplied file %s has no known extension. containerit will handle it as an R script for packaging.", file)
      sessionInfo <- clean_session(script_file = rel_file,
                                   echo = !silent,
                                   predetect = predetect)
    }

    # append system dependencies and package installation instructions
    the_dockerfile <- dockerfileFromSession(session = sessionInfo,
                                            base_dockerfile = base_dockerfile,
                                            soft,
                                            offline,
                                            add_self,
                                            add_loadedOnly,
                                            versioned_libs,
                                            versioned_packages,
                                            filter_baseimage_pkgs,
                                            workdir)

    # WORKDIR must be set before, now add COPY instructions
    the_dockerfile <- .handleCopy(the_dockerfile, copy, context, fromFile)

    return(the_dockerfile)
  }

dockerfileFromWorkspace <- function(path,
                                    base_dockerfile,
                                    soft,
                                    copy,
                                    offline,
                                    add_self,
                                    add_loadedOnly,
                                    silent,
                                    predetect,
                                    versioned_libs,
                                    versioned_packages,
                                    filter_baseimage_pkgs,
                                    workdir) {
    futile.logger::flog.debug("Creating from workspace directory")
    target_file <- NULL #file to be packaged

    .rFiles <- dir(path = path,
                   pattern = "\\.R$",
                   full.names = TRUE,
                   include.dirs = FALSE,
                   recursive = TRUE,
                   ignore.case = TRUE)

    .md_Files <- dir(path = path,
                     pattern = "\\.Rmd$", #|\\.Rnw$",
                     full.names = TRUE,
                     include.dirs = FALSE,
                     recursive = TRUE,
                     ignore.case = TRUE)
    futile.logger::flog.debug("Found %s scripts and %s documents", length(.rFiles), length(.md_Files))

    if (length(.rFiles) > 0 && length(.md_Files) > 0) {
      target_file <- .md_Files[1]
      warning("Found both scripts and weaved documents (Rmd) in the given directory. Using the first document for packaging: \n\t",
              target_file)
    } else if (length(.md_Files) > 0) {
      target_file <- .md_Files[1]
      if (length(.md_Files) > 1)
        warning("Found ", length(.md_Files), " document files in the workspace, using '", target_file, "'")
    } else if (length(.rFiles) > 0) {
      target_file <- .rFiles[1]
      if (length(.rFiles) > 1)
        warning("Found ", length(.rFiles), " script files in the workspace, using '", target_file, "'")
    }

    if (is.null(target_file))
      stop("Workspace does not contain any R file that can be packaged.")
    else
      futile.logger::flog.info("Found file for packaging in workspace: %s", target_file)

    the_dockerfile <- dockerfileFromFile(fromFile = target_file,
                                         base_dockerfile,
                                         soft,
                                         copy,
                                         offline,
                                         add_self,
                                         add_loadedOnly,
                                         silent,
                                         predetect,
                                         versioned_libs,
                                         versioned_packages,
                                         filter_baseimage_pkgs,
                                         workdir)
    return(the_dockerfile)
  }

dockerfileFromDescription <- function(description,
                                      base_dockerfile,
                                      soft,
                                      copy,
                                      offline,
                                      versioned_libs,
                                      versioned_packages,
                                      filter_baseimage_pkgs,
                                      workdir) {
  futile.logger::flog.debug("Creating from description")
  stopifnot(inherits(x = description, "description"))

  # only add imported packages
  type <- NULL # avoid NOTE, see https://stackoverflow.com/a/8096882/261210
  pkgs <- subset(description$get_deps(), type == "Imports")$package

  # only add itself when `Repository: CRAN`
  if (!is.na(description$get_field("Repository", default = NA))
      && description$get_field("Repository") == "CRAN")
    pkgs <- c(description$get_field("Package"), pkgs)

  # parse remotes with remotes internal functions
  remote_pkgs <- remotes:::split_extra_deps(description$get_remotes())

  # add CRAN packages
  pkgs_list <- lapply(pkgs, function(pkg) {
    name <- pkg
    source <- "CRAN"
    version <- NA
    if (description$get_field("Package") == pkg)
      version <- as.character(description$get_version())
    return(list(name = name, version = version, source = source))
  })

  # add remote packages
  pkgs_list <- append(pkgs_list, lapply(remote_pkgs, function(remote) {
    remote_pkg <- remotes:::parse_one_extra(remote)
    if (inherits(remote_pkg, "github_remote")) {
      # assume package name == repo name !
      name <- remote_pkg$repo
      source <- "github"
      version <- paste0(remote_pkg$username, "/", remote_pkg$repo, "@", remote_pkg$ref)
      return(list(name = name, version = version, source = source))
    } else {
      futile.logger::flog.warn("Unsupported remote found in DESCRIPTION file: %s", toString(remote))
      return(NULL)
    }
  }))
  # remove NULLs
  pkgs_list <- pkgs_list[!vapply(pkgs_list, is.null, logical(1))]

  packages_df <- do.call("rbind", lapply(pkgs_list, as.data.frame))
  futile.logger::flog.debug("Found %s packages in sessionInfo", nrow(packages_df))

  platform = NULL
  image_name = base_dockerfile@image@image
  if (image_name %in% .debian_images) {
    platform = .debian_platform
    futile.logger::flog.debug("Found image %s in list of Debian images", image_name)
  }
  futile.logger::flog.debug("Detected platform: %s", platform)

  the_dockerfile <- dockerfileFromPackages(pkgs = packages_df,
                                           base_dockerfile,
                                           soft,
                                           offline,
                                           versioned_libs,
                                           versioned_packages,
                                           filter_baseimage_pkgs,
                                           workdir)

  # WORKDIR must be set before, now add COPY instructions
  the_dockerfile <- .handleCopy(the_dockerfile, copy, fs::path_norm(getwd()))

  return(the_dockerfile)
}

.tagsfromRemoteImage <- function(image) {
  urlstr <- paste0("https://registry.hub.docker.com/v2/repositories/",
                   image,
                   "/tags/?page_size=9999")
  str <- NULL

  futile.logger::flog.debug("Retrieving tags for image %s with %s", image, urlstr)
  tryCatch({
    con <- url(urlstr)
    str <- readLines(con, warn = FALSE)
    },
    error = function(e) {
      stop("Could not retrieve existing tags from ", urlstr, " (offline?), error: ", e)
    },
    finally = close(con))

  if (is.null(str)) {
    return(c())
  } else {
    parser <- rjson::newJSONParser()
    parser$addData(str)
    tags <- sapply(parser$getObject()$results, function(x) {
      x$name
    })
    return(tags)
  }
}

.handleCopy <- function(the_dockerfile, copy, context, the_file = NULL) {
  futile.logger::flog.debug("Creating COPY with in working directory %s using: %s", context, toString(copy))

  if (!all(is.null(copy)) && !all(is.na(copy))) {
    copy = unlist(copy)
    if (!is.character(copy)) {
      stop("Invalid argument given for 'copy'")
    } else if (length(copy) == 1 && copy == "script") {
      if (is.null(the_file))
        stop("If 'script' is used, the 'from' input must be a support file type")
      rel_path <- fs::path_rel(the_file, context)
      #unless we use some kind of Windows-based Docker images, the destination path has to be unix compatible:
      rel_path_dest <- stringr::str_replace_all(rel_path, pattern = "\\\\", replacement = "/")
      rel_path_source <- stringr::str_replace_all(rel_path, pattern = "\\\\", replacement = "/")
      addInstruction(the_dockerfile) <- Copy(rel_path_source, rel_path_dest)
    } else if (length(copy) == 1 && copy == "script_dir") {
      script_dir <- normalizePath(dirname(the_file))
      rel_dir <- fs::path_rel(script_dir, context)

      #unless we use some kind of Windows-based Docker images, the destination path has to be unix compatible:
      rel_dir_dest <- stringr::str_replace_all(rel_dir, pattern = "\\\\", replacement = "/")
      addInstruction(the_dockerfile) <- Copy(rel_dir, rel_dir_dest)
    } else {
      futile.logger::flog.debug("We have a list of paths/files in 'copy': ", toString(copy))
      copy_instructions <- sapply(copy, function(the_file) {
        if (file.exists(the_file)) {
          futile.logger::flog.debug("Adding COPY instruction for file ", the_file)
          rel_path <- fs::path_rel(the_file, context)
          # turn into unix path
          rel_path_dest <- stringr::str_replace_all(rel_path, pattern = "\\\\", replacement = "/")

          return(Copy(rel_path, rel_path_dest))
        } else {
          warning("The file ", the_file, ", provided in 'copy', does not exist!")
          return(NULL)
        }
      })

      copy_instructions[sapply(copy_instructions, is.null)] <- NULL
      addInstruction(the_dockerfile) <- copy_instructions
    }
  } else {
    futile.logger::flog.debug("All paths in copy are NULL or NA, not adding any COPY instructions: ", toString(copy))
  }

  return(the_dockerfile)
}
