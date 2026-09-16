## Node for darwin A10 CPU
By default, Node arm64 macOS builds configure all processor instruction sets according to the M series. 
If you attempt to patch these binaries using a tool like [machomorph](https://github.com/mowisec/macos-to-ios) 
and run them on an A10 (ARMv8.0-A) processor, the application will give Illegal Instruction error. 
You can use this workflow to workaround this error using Github Actions. 
To compile a different version, simply edit the VERSION and EXPECT_SHA lines 
in the bash script and run the Workflow manually.

The macOS-15 runner completed version 24.20.0 with Full ICU in 73 minutes.
