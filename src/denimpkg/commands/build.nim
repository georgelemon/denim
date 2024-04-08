import std/[os, osproc, json, strutils]
import kapsis/[cli, runtime]
import ../utils

proc getNodeGypConfig(getNimPath: string, release: bool = false): JsonNode = 
  return %* {
    "target_name": "main",
    "include_dirs": [
      getNimPath
    ],
    "cflags": if release: %*["-w", "-O3", "-fno-strict-aliasing"] else: %*["-w"],
    "linkflags": ["-ldl"]
  }

const cMakeListsContent = """
cmake_minimum_required(VERSION 3.15)
cmake_policy(SET CMP0091 NEW)
cmake_policy(SET CMP0042 NEW)

project (DENIM_PKG_NAME)

add_definitions(-DNAPI_VERSION=4)

include_directories(${CMAKE_JS_INC})

file(GLOB SOURCE_FILES "./denim_build/nimcache/*.c" "./denim_build/nimcache/*.h")

add_library(${PROJECT_NAME} SHARED ${SOURCE_FILES} ${CMAKE_JS_SRC})
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX PREFIX "" SUFFIX ".node")
target_link_libraries(${PROJECT_NAME} ${CMAKE_JS_LIB})

if(MSVC AND CMAKE_JS_NODELIB_DEF AND CMAKE_JS_NODELIB_TARGET)
  # Generate node.lib
  execute_process(COMMAND ${CMAKE_AR} /def:${CMAKE_JS_NODELIB_DEF} /out:${CMAKE_JS_NODELIB_TARGET} ${CMAKE_STATIC_LINKER_FLAGS})
endif()
"""

proc buildCommand*(v: Values) =
  ## Compile project to source code by using Nim compiler
  # https://nim-lang.org/docs/nimc.html
  let inputFile = v.get("nim").getPath().path
  var
    currDir = getCurrentDir()
    addonPathDirectory = utils.getPath(currDir, "" / "denim_build")
    cachePathDirectory = addonPathDirectory / "nimcache"
    path = splitPath(inputFile)
    entryFile = path.tail
  if not entryFile.endsWith(".nim") or fileExists(inputFile) == false:
    display("Missing '.nim' file", indent=2)
    QuitFailure.quit

  if not isEmptyDir(addonPathDirectory):
    echo addonPathDirectory
    if not v.has("y"):
      display("Directory is not empty: " & os.splitPath(addonPathDirectory).tail, indent=2, br="after")
      if promptConfirm("👉 Are you sure you want to remove contents?"):
        os.removeDir(addonPathDirectory)
      else:
        display("Canceled", indent=2, br="after")
        QuitFailure.quit
    else:
      os.removeDir(addonPathDirectory)
  display("🔥 Running Nim Compiler", indent=2, br="both")
    
  var args = @[
    "--nimcache:$1",
    "--define:napibuild",
    "--compileOnly",
    "--noMain",
  ]

  if v.has("release"):
    add args, "-d:release"
    add args, "--opt:speed"
  else:
    add args, "--embedsrc"

  let nimc = "nim c " & args.join(" ") & " $2"
  let nimCmd = execCmdEx(nimc % [
    cachePathDirectory,
    utils.getPath(currDir, "" / "$#".format(inputFile))
  ])
  if nimCmd.exitCode != 0:
    display(nimCmd.output)
    QuitFailure.quit
  elif v.has("verbose"):
    display(nimCmd.output)
  var getNimPath = execCmdEx("choosenim show path")
  if getNimPath.exitCode != 0:
    display("Can't find Nim path")
    QuitFailure.quit
  discard execProcess("ln", args = [
    "-s",
    strip(getNimPath.output) / "lib" / "nimbase.h",
    cachePathDirectory
  ], options={poStdErrToStdOut, poUsePath})
  
  if v.has("cmake"):
    display("✨ Building with CMake.js", indent=2, br="after")
    writeFile(currDir / "CMakeLists.txt", cMakeListsContent.replace("DENIM_PKG_NAME", entryFile.splitFile.name))
    let cmakeCmd = execCmdEx("cmake-js compile --runtime node --out " & "denim_build" / "build")
    if cmakeCmd.exitCode != 0:
      display(cmakeCmd.output)
      QuitFailure.quit
    elif v.has("verbose"):
      display(cmakeCmd.output)
  else:
    display("✨ Building with node-gyp", indent=2, br="after")
    var
      gyp = %* {"targets": [getNodeGypConfig(getNimPath.output.strip, v.has("release"))]}
      jsonConfigPath = cachePathDirectory / entryFile.replace(".nim", ".json")
    var
      jarr = newJArray()
      jsonConfigContents = parseJson(readFile(jsonConfigPath))
    for elem in items(jsonConfigContents["compile"].elems):
      jarr.add(newJString(elem[0].getStr().replace(addonPathDirectory / "", "")))
    gyp["targets"][0]["sources"] = %* jarr
    writeFile(addonPathDirectory / "binding.gyp", pretty(gyp, 2))
    let gypCmd = execCmdEx("node-gyp rebuild --directory=" & addonPathDirectory)
    if gypCmd.exitCode != 0:
      display(gypCmd.output)
      QuitFailure.quit
    elif v.has("verbose"):
      display(gypCmd.output)
  let
    defaultBinName =
      if v.has("cmake"):
        entryFile.splitFile.name
      else: "main"
    binaryNodePath = utils.getPath(currDir, "" / "denim_build" / "build" / "Release" / defaultBinName & ".node")
    binDirectory = currDir / "bin"
    binName = entryFile.replace(".nim", ".node")
    binaryTargetPath = binDirectory / binName

  if fileExists(binaryNodePath) == false:
    display("👉 Oups! $1 not found. Try build again" % [binName], indent=2)
    QuitFailure.quit
  else:
    discard existsOrCreateDir(binDirectory)              # ensure bin directory exists
    moveFile(binaryNodePath, binaryTargetPath)           # move .node addon
    display("👌 Done! Check your /bin directory", indent=2, br="after")
    QuitSuccess.quit
