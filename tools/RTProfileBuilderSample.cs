﻿#region Usings
using System;
using System.Text;
using System.IO;
using System.Globalization;
using System.Diagnostics;
using System.Configuration;
using System.Collections;
using System.Collections.Specialized;
#endregion

// Raw Therapee sample Custom Profile builder (version 2010-11-08)
// WARNING: PP3 format may change in the future versions! If this happens there will probably be no automatic migration path, you'll have to adjust on your own.
//
// How to use:
// 1. Modify the GetCorrectedSettings function below according to your needs.
// 2. Download and install Microsoft .Net Runtime (latest version is 4.0 as of writing), if it's not already on your machine.
//    You can get it for free via Windows Update or from microsoft.com. No need for Visual Studio etc.
// 3. Open a command line and compile this CS-File using the C# 32bit compiler. It is usually installed somewhere here:
//    C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe
//    Call csc.exe with your .CS file as parameter. CSC will compile it and emit an EXE.
// 4. Open your RT options files and find the entry [Profiles]/CustomProfileBuilder
// 5. Enter the path to your newly built exe here. On Windows, don't forget double slashes (e.g. "C:\\MyDir\\Mybuilder.exe")
// And you're done! The EXE is only called on opening the image editor and there is no PP3 already
// 
// If you want to use EXIFTOOL to gather more details information to build queries:
// 1. Download exiftool.exe from http://www.sno.phy.queensu.ca/~phil/exiftool/
// 2. Rename it to exiftool.exe (NOT exiftool(-k).. or something!)
// 3. Copy the RTProfilerBuilder.exe.config next to your own EXE. If you renamed it, rename config to "(Yourname).exe.config"
// 4. Open the config with notepad (it's an XML file). Set ExifToolPath to your downloaded and renamed exe
//
// If you want to know what parameters are available, call "exiftool.exe <raw file name> -tab -short"
//
// This description is for Windows. The C# code does not use anything fancy, will probably work with MONO on Linux/OSX, too

namespace RTProfilerBuilder {
	/// <summary>Main class. Mostly change GetCorrectedSettings.</summary>
	class RTProfileBuilder {

		/// <summary>This is your personalisation function</summary>
		/// <param name="exif">Full EXIF from EXIFTOOL (if configured).</param>
		/// <param name="sectionEntry">Entry, like "Sharpening/Radius"</param>
		/// <param name="value">Current value (from default file)</param>
		/// <param name="fNumber">FNumber</param><param name="exposureSecs">Exposure in seconds</param>
		/// <param name="focalLength">Focal length in MM</param><param name="iso">ISO value</param>
		/// <param name="lens">Lens from EXIF</param><param name="camera">Camera from EXIF</param>
		/// <returns>The value to be written. Simply take the current value if you have nothing to touch.</returns>
		static string GetCorrectedSetting(NameValueCollection exif, string sectionEntry, string value,
			float fNumber, float exposureSecs, float focalLength, long iso, string lens, string camera) {

			string s;

			// We don't do anything to the value if it's not our camera
			if (camera.EndsWith("NIKON D700", StringComparison.InvariantCultureIgnoreCase) && lens.Contains("24.0-120.0")) {
				switch (sectionEntry) {
					// Here is the place to adjust your settings
					// Pretty simple: "SectionName/EntryName" in options file

					case "Vignetting Correction/Amount":
						value = (fNumber < 8 && focalLength < 30) ? "30" : "0";
						break;

					case "RAW/CA":
						value = ToBool(fNumber < 11);  // Means "Enabled if fnumber<11, otherwise disabled"
						break;

					case "Impulse Denoising/Enabled":
						value = ToBool(iso >= 3200);
						break;

					case "HLRecovery/Enabled":
						value = ToBool(iso >= 1600);  // Dynamic range decreases, so we'll probably need it
						break;

					case "Color Boost/Amount":
						if (iso >= 6400) value = "0";  // Colors will get poppy anyway...
						break;

					// Add other parameters here. Mention this is case sensitive!

					default: break;  // we don't touch values we don't care about
				}
			}  // end if camera=xxx


			// This is for camera independend settings
			switch (sectionEntry) {
				// These are parsed from EXIFTOOL and XMP in DNG (see http://en.wikipedia.org/wiki/Extensible_Metadata_Platform)
				case "IPTC/City":
					s = exif.Get("City");
					if (!String.IsNullOrEmpty(s)) value = s;
					break;

				case "IPTC/Country":
					s = exif.Get("Country");
					if (!String.IsNullOrEmpty(s)) value = s;
					break;

				case "IPTC/Caption":
				case "IPTC/Title":
					s = exif.Get("Headline");
					if (!String.IsNullOrEmpty(s)) value = s;
					break;

				// Add other parameters here. Mention this is case sensitive!

				default: break;  // we don't touch values we don't care about
			}
			return value;
		}

		#region * Main and Helpers
		static string ToBool(bool condition) { return condition ? "true" : "false"; }
		static string ToFloat(float f) { return f.ToString(CultureInfo.InvariantCulture); }

		/// <summary>Reads default file and parses it. No need to touch it for your personal settings.</summary>
		/// <param name="args">Command line args</param>
		/// <return>0 on all OK.</return>
		static int Main(string[] args) {
			int exitCode = 0;

			try {
				#region Parse input parameters
				int argNo = 0;

				// Name of RAW/JPG to process
				string sourceFile = args[argNo++];

				// What the user selected as his base profile
				string defaultProfileFilePath = args[argNo++];

				// Note that old C++ has no automatic number globalization
				float fNumber = float.Parse(args[argNo++], CultureInfo.InvariantCulture);
				float exposureSecs = float.Parse(args[argNo++], CultureInfo.InvariantCulture);
				float focalLength = float.Parse(args[argNo++], CultureInfo.InvariantCulture);
				long iso = long.Parse(args[argNo++], CultureInfo.InvariantCulture);

				string lens = args[argNo++];
				string camera = args[argNo++];
				#endregion

				// Read default file as basis
				string[] lines = File.ReadAllLines(defaultProfileFilePath);

				NameValueCollection nvEXIF = ParseFullExifData(sourceFile);

				// File should be Windows ANSI
				using (TextWriter tw = new StreamWriter(sourceFile + ".pp3", false, Encoding.Default)) {
					string section = "";

					foreach (string line in lines) {
						string l = line.Trim();
						if (!String.IsNullOrEmpty(line)) {

							if (l.StartsWith("["))
								section = l.Trim(new char[] { '[', ']' });
							else if (char.IsLetterOrDigit(l[0]) && l.Contains("=")) {
								int valPos = l.IndexOf("=") + 1;

								string newValue = GetCorrectedSetting(nvEXIF, section + "/" + l.Substring(0, valPos - 1), l.Substring(valPos).Trim(),
									fNumber, exposureSecs, focalLength, iso, lens, camera);

								// Merge in new value
								l = l.Substring(0, valPos) + (newValue ?? "");
							}
						}

						tw.WriteLine(l);
					}
				}

			} catch (Exception ex) {
				Console.WriteLine("Error: " + ex.ToString());  // can be seen in the RT console window

				exitCode = 1;
			}

			return exitCode;
		}


		static NameValueCollection ParseFullExifData(string filePath) {
			NameValueCollection nv = new NameValueCollection();

			string exifToolPath = ConfigurationManager.AppSettings["ExifToolPath"];
			if (!String.IsNullOrEmpty(exifToolPath)) {
				ProcessStartInfo psi = new ProcessStartInfo(exifToolPath, "\"" + filePath + "\" -tab -short");
				psi.CreateNoWindow = false;
				psi.UseShellExecute = false;
				psi.RedirectStandardOutput = true;

				Process p = Process.Start(psi);

				using (StreamReader sr = p.StandardOutput) {
					while (!sr.EndOfStream) {
						string line = sr.ReadLine();
						if (line.Contains("\t")) {
							string[] split = line.Split('\t');
							nv.Add(split[0], split[1]);
						}
					}
				}

				p.WaitForExit();
			}

			return nv;
		}

		#endregion
	}
}