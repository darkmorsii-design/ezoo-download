fn main() {
    // "fluent" follows the light/dark switch the app makes at runtime
    // Arabic texts: lang/ar/LC_MESSAGES/swiftget.po (made by lang/make_po.py)
    let config = slint_build::CompilerConfiguration::new()
        .with_style("fluent".into())
        .with_bundled_translations("lang")
        .with_default_translation_context(slint_build::DefaultTranslationContext::None);
    println!("cargo:rerun-if-changed=lang/ar/LC_MESSAGES/swiftget.po");
    slint_build::compile_with_config("ui/app.slint", config).expect("Slint UI failed to compile");

    // Icon, full version information and a standard manifest for
    // EzooDownload.exe. Antivirus programs trust a program more when it says
    // clearly who made it, what it is and that it runs without admin rights.
    #[cfg(windows)]
    {
        let version = env!("CARGO_PKG_VERSION");
        let mut res = winresource::WindowsResource::new();
        res.set_icon("icon.ico");
        res.set("ProductName", "Ezoo Download");
        res.set("FileDescription", "Ezoo Download");
        res.set("CompanyName", "Ezoo");
        res.set("LegalCopyright", "Copyright (C) 2026 Ahmed Ezzat");
        res.set("OriginalFilename", "EzooDownload.exe");
        res.set("InternalName", "EzooDownload");
        res.set("ProductVersion", version);
        res.set("FileVersion", version);
        res.set_manifest(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="Ezoo.EzooDownload" version="1.0.0.0" processorArchitecture="*"/>
  <description>Ezoo Download - download manager</description>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <!-- Vista, 7, 8, 8.1 and 10/11: without these lines Windows 7 would run the
       program in "compatibility mode" -->
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{e2011457-1546-43c5-a5fe-008deee3d3f0}"/>
      <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
</assembly>
"#,
        );
        if let Err(e) = res.compile() {
            println!("cargo:warning=could not embed the Windows icon: {e}");
        }
    }
}
