"""
Audio preprocessing module for noise reduction and enhancement.
Handles radio static, background noise, and signal quality issues.
Supports an aggressive radio-static mode for very noisy VHF recordings.
"""

import numpy as np
import librosa
import noisereduce as nr
from scipy import signal
from typing import Optional, Tuple
import soundfile as sf


# Speech band for narrowband radio (Hz). Aggressive filtering outside this reduces static.
SPEECH_LOW_HZ = 250.0
SPEECH_HIGH_HZ = 3800.0


class AudioPreprocessor:
    """
    Audio preprocessing for ATC communications with noise reduction.
    Use aggressive_radio=True for heavy radio static and hiss.
    """
    
    def __init__(
        self,
        sample_rate: int = 16000,
        enable_noise_reduction: bool = True,
        enable_spectral_gating: bool = True,
        enable_highpass: bool = True,
        highpass_freq: float = 300.0,
        aggressive_radio: bool = False,
        enable_bandpass: bool = False,
        bandpass_low: float = SPEECH_LOW_HZ,
        bandpass_high: float = SPEECH_HIGH_HZ,
    ):
        """
        Initialize audio preprocessor.
        
        Args:
            sample_rate: Target sample rate (Whisper uses 16kHz)
            enable_noise_reduction: Use noisereduce library
            enable_spectral_gating: Apply spectral gating for noise suppression
            enable_highpass: Apply high-pass filter to remove low-frequency noise
            highpass_freq: High-pass filter cutoff frequency (Hz)
            aggressive_radio: Use stronger settings for heavy radio static/hiss
            enable_bandpass: Constrain to speech band (reduces out-of-band static)
            bandpass_low: Low cutoff for bandpass (Hz)
            bandpass_high: High cutoff for bandpass (Hz)
        """
        self.sample_rate = sample_rate
        self.enable_noise_reduction = enable_noise_reduction
        self.enable_spectral_gating = enable_spectral_gating
        self.enable_highpass = enable_highpass
        self.highpass_freq = highpass_freq
        self.aggressive_radio = aggressive_radio
        self.enable_bandpass = enable_bandpass or aggressive_radio
        self.bandpass_low = bandpass_low
        self.bandpass_high = min(bandpass_high, (sample_rate / 2) * 0.95)
        
        # Aggressive preset overrides
        if aggressive_radio:
            self.highpass_freq = 350.0
            self.enable_bandpass = True
        
        # Initialize noise profile (will be learned from first few seconds)
        self.noise_profile = None
        self.noise_profile_samples = []
        self.noise_profile_collected = False
    
    def collect_noise_profile(self, audio: np.ndarray, duration: float = 1.0):
        """
        Collect noise profile from silent/noise-only segments.
        
        Args:
            audio: Audio array
            duration: Duration in seconds to use for noise profile
        """
        samples = int(duration * self.sample_rate)
        if len(audio) > samples:
            # Use first portion (typically contains noise before speech)
            self.noise_profile_samples.append(audio[:samples])
            self.noise_profile = np.concatenate(self.noise_profile_samples)
            self.noise_profile_collected = True
    
    def apply_highpass_filter(self, audio: np.ndarray) -> np.ndarray:
        """Apply high-pass filter to remove low-frequency noise."""
        if not self.enable_highpass:
            return audio
        
        # Design high-pass filter
        nyquist = self.sample_rate / 2
        normalized_cutoff = self.highpass_freq / nyquist
        normalized_cutoff = min(normalized_cutoff, 0.99)
        
        # Butterworth high-pass filter (order 4 default; 5 for aggressive)
        order = 5 if self.aggressive_radio else 4
        b, a = signal.butter(order, normalized_cutoff, btype='high')
        filtered_audio = signal.filtfilt(b, a, audio)
        
        return filtered_audio
    
    def apply_bandpass_filter(self, audio: np.ndarray) -> np.ndarray:
        """Apply bandpass to keep only speech band and remove out-of-band radio static."""
        if not self.enable_bandpass:
            return audio
        nyquist = self.sample_rate / 2
        low = max(50.0, self.bandpass_low) / nyquist
        high = min(nyquist - 100, self.bandpass_high) / nyquist
        if low >= high:
            return audio
        low = min(low, 0.98)
        high = min(high, 0.98)
        b, a = signal.butter(4, [low, high], btype='band')
        return signal.filtfilt(b, a, audio)
    
    def apply_spectral_gating(self, audio: np.ndarray, threshold_db: Optional[float] = None) -> np.ndarray:
        """
        Apply spectral gating to suppress noise (e.g. radio hiss).
        In aggressive mode uses a lower threshold and stronger suppression.
        """
        if not self.enable_spectral_gating:
            return audio
        
        if threshold_db is None:
            threshold_db = -35.0 if self.aggressive_radio else -40.0
        suppress_db = 25.0 if self.aggressive_radio else 20.0  # How much to cut below threshold
        
        n_fft = 2048
        hop_length = 512
        stft = librosa.stft(audio, n_fft=n_fft, hop_length=hop_length)
        magnitude = np.abs(stft)
        phase = np.angle(stft)
        magnitude_db = librosa.amplitude_to_db(magnitude)
        
        gated_magnitude_db = np.where(
            magnitude_db > threshold_db,
            magnitude_db,
            magnitude_db - suppress_db
        )
        gated_magnitude = librosa.db_to_amplitude(gated_magnitude_db)
        stft_processed = gated_magnitude * np.exp(1j * phase)
        audio_processed = librosa.istft(stft_processed, hop_length=hop_length, length=len(audio))
        
        return audio_processed
    
    def apply_noise_reduction(self, audio: np.ndarray) -> np.ndarray:
        """
        Apply noise reduction using noisereduce (stationary profile for radio static).
        Aggressive mode uses higher prop_decrease and optionally a second pass.
        """
        if not self.enable_noise_reduction:
            return audio
        
        prop = 0.95 if self.aggressive_radio else 0.8
        n_fft = 2048 if self.aggressive_radio else 1024
        
        try:
            if self.noise_profile_collected and self.noise_profile is not None:
                reduced = nr.reduce_noise(
                    y=audio,
                    sr=self.sample_rate,
                    y_noise=self.noise_profile,
                    stationary=True,
                    prop_decrease=prop,
                    n_fft=n_fft,
                    freq_mask_smooth_hz=250,
                    time_mask_smooth_ms=100,
                )
            else:
                reduced = nr.reduce_noise(
                    y=audio,
                    sr=self.sample_rate,
                    stationary=True,
                    prop_decrease=prop,
                    n_fft=n_fft,
                    freq_mask_smooth_hz=250,
                    time_mask_smooth_ms=100,
                )
            reduced = reduced.astype(np.float32)
            # Second pass for aggressive: further reduce residual stationary noise
            if self.aggressive_radio:
                reduced = nr.reduce_noise(
                    y=reduced,
                    sr=self.sample_rate,
                    stationary=True,
                    prop_decrease=0.7,
                    n_fft=1024,
                )
                reduced = reduced.astype(np.float32)
            return reduced
        except Exception as e:
            print(f"Warning: Noise reduction failed: {e}")
            return audio
    
    def normalize_audio(self, audio: np.ndarray) -> np.ndarray:
        """Normalize audio to prevent clipping."""
        max_val = np.max(np.abs(audio))
        if max_val > 0:
            # Normalize to 0.95 to prevent clipping
            audio = audio / max_val * 0.95
        return audio
    
    def preprocess(
        self,
        audio: np.ndarray,
        collect_noise: bool = False
    ) -> np.ndarray:
        """
        Apply full preprocessing pipeline.
        
        Args:
            audio: Input audio array
            collect_noise: Whether to collect noise profile from this audio
            
        Returns:
            Preprocessed audio array
        """
        # Ensure float32
        if audio.dtype != np.float32:
            audio = audio.astype(np.float32)
        
        # Collect noise profile if requested
        if collect_noise and not self.noise_profile_collected:
            self.collect_noise_profile(audio)
        
        # Apply preprocessing: highpass -> bandpass (speech band) -> spectral gating -> noise reduction -> normalize
        audio = self.apply_highpass_filter(audio)
        audio = self.apply_bandpass_filter(audio)
        audio = self.apply_spectral_gating(audio)
        audio = self.apply_noise_reduction(audio)
        audio = self.normalize_audio(audio)
        
        return audio
    
    def preprocess_file(
        self,
        input_path: str,
        output_path: Optional[str] = None,
        collect_noise: bool = False
    ) -> np.ndarray:
        """
        Preprocess audio file.
        
        Args:
            input_path: Path to input audio file
            output_path: Optional path to save preprocessed audio
            collect_noise: Whether to collect noise profile
            
        Returns:
            Preprocessed audio array
        """
        # Load audio
        audio, sr = librosa.load(input_path, sr=self.sample_rate, mono=True)
        
        # Preprocess
        audio_processed = self.preprocess(audio, collect_noise=collect_noise)
        
        # Save if output path provided
        if output_path:
            sf.write(output_path, audio_processed, self.sample_rate)
        
        return audio_processed


def create_preprocessor(config: dict) -> AudioPreprocessor:
    """Create preprocessor from configuration dictionary."""
    return AudioPreprocessor(
        sample_rate=config.get("sample_rate", 16000),
        enable_noise_reduction=config.get("enable_noise_reduction", True),
        enable_spectral_gating=config.get("enable_spectral_gating", True),
        enable_highpass=config.get("enable_highpass", True),
        highpass_freq=config.get("highpass_freq", 300.0),
        aggressive_radio=config.get("aggressive_radio", False),
        enable_bandpass=config.get("enable_bandpass", False),
        bandpass_low=config.get("bandpass_low", SPEECH_LOW_HZ),
        bandpass_high=config.get("bandpass_high", SPEECH_HIGH_HZ),
    )

