package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.util.Log;

import androidx.activity.EdgeToEdge;
import androidx.core.splashscreen.SplashScreen;

public class GodotApp extends GodotActivity {
	public static native void initializeMoonlightJNI();
	public static native void setAndroidContext(Object context);

	public static String jniResult = "NOT_RUN";
	public static boolean nativeLibraryLoaded = false;
	public static DepthEstimator depthEstimator;
	public static WifiManager.MulticastLock multicastLock;

	static {
		if (BuildConfig.FLAVOR.equals("mono")) {
			try {
				Log.v("GODOT", "Loading System.Security.Cryptography.Native.Android library");
				System.loadLibrary("System.Security.Cryptography.Native.Android");
			} catch (UnsatisfiedLinkError e) {
				Log.e("GODOT", "Unable to load System.Security.Cryptography.Native.Android library");
			}
		}
		// The GDExtension .so is named after the Godot build variant it targets,
		// so a debug APK ships template_debug and a release APK template_release.
		// Try both: loading only the release name leaves the native methods
		// unbound in a debug build, and the first call to one of them (see
		// onCreate) then throws an uncaught UnsatisfiedLinkError.
		Throwable loadError = null;
		for (String lib : new String[] {
					"nightfall-stream.android.template_release.arm64",
					"nightfall-stream.android.template_debug.arm64" }) {
			try {
				System.loadLibrary(lib);
				loadError = null;
				break;
			} catch (Throwable e) {
				loadError = e;
			}
		}
		if (loadError == null) {
			try {
				initializeMoonlightJNI();
				jniResult = "SUCCESS";
				nativeLibraryLoaded = true;
			} catch (Throwable e) {
				jniResult = "FAILED: " + e.getClass().getName() + ": " + e.getMessage();
			}
		} else {
			jniResult = "FAILED: " + loadError.getClass().getName() + ": " + loadError.getMessage();
		}
		if (!nativeLibraryLoaded) {
			Log.e("GODOT", "nightfall-stream native library not loaded: " + jniResult);
		}
	}

	public static void acquireMulticastLock(Context context) {
		if (multicastLock != null) return;
		try {
			WifiManager wifi = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);
			if (wifi != null) {
				multicastLock = wifi.createMulticastLock("nightfall-mdns");
				multicastLock.setReferenceCounted(false);
				multicastLock.acquire();
				Log.i("GODOT", "MulticastLock acquired for mDNS discovery");
			}
		} catch (Exception e) {
			Log.e("GODOT", "Failed to acquire MulticastLock: " + e.getMessage());
		}
	}

	private final Runnable updateWindowAppearance = () -> {
		Godot godot = getGodot();
		if (godot != null) {
			godot.enableImmersiveMode(godot.isInImmersiveMode(), true);
			godot.enableEdgeToEdge(godot.isInEdgeToEdgeMode(), true);
			godot.setSystemBarsAppearance();
		}
	};

	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen.installSplashScreen(this);
		EdgeToEdge.enable(this);
		super.onCreate(savedInstanceState);
		// Native methods are only bound if the static initializer loaded the
		// library. Calling one otherwise throws an uncaught UnsatisfiedLinkError
		// and kills the app during launch, hiding the real cause.
		if (nativeLibraryLoaded) {
			setAndroidContext(getApplicationContext());
		} else {
			Log.e("GODOT", "Skipping setAndroidContext, native library unavailable: " + jniResult);
		}
		acquireMulticastLock(getApplicationContext());
		depthEstimator = new DepthEstimator();
		depthEstimator.initialize(getApplicationContext());
		Log.i("GODOT", "DepthEstimator initialized: " + depthEstimator.isInitialized());
		try {
			java.io.FileOutputStream fos = openFileOutput("jni_result.txt", MODE_PRIVATE);
			fos.write(jniResult.getBytes());
			fos.close();
		} catch (Exception ignored) {}
	}

	public static void submitDepthFrame(byte[] pixels, int w, int h) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.submitFrame(pixels, w, h);
		}
	}

	public static byte[] getLatestDepthMap() {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			return depthEstimator.getLatestDepth();
		}
		return null;
	}

	public static void setDepthModel(int modelIndex) {
		if (depthEstimator != null && depthEstimator.isInitialized()) {
			depthEstimator.setActiveModel(modelIndex);
		}
	}

	@Override
	public void onResume() {
		super.onResume();
		updateWindowAppearance.run();
	}

	@Override
	public void onGodotMainLoopStarted() {
		super.onGodotMainLoopStarted();
		runOnUiThread(updateWindowAppearance);
	}

	@Override
	public void onGodotForceQuit(Godot instance) {
		if (!BuildConfig.FLAVOR.equals("instrumented")) {
			super.onGodotForceQuit(instance);
		}
	}
}
