#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import smtplib
import ssl
import tkinter as tk
from tkinter import ttk, messagebox
from email.mime.text import MIMEText

# -------------------------
# Fonctions SMTP
# -------------------------
def get_smtp_settings(provider):
    """Retourne (host, port, ssl_enabled, starttls_enabled) selon provider."""
    if provider == "Gmail":
        # Gmail : STARTTLS sur 587 (ou SSL 465 si demandé)
        return ("smtp.gmail.com", 587, False, True)
    elif provider == "Office365":
        # Office365 : recommandation STARTTLS sur 587
        return ("smtp.office365.com", 587, False, True)
    else:
        # fallback pour les cas non gérés (Custom lu séparément)
        return ("smtp.example.com", 587, False, True)

def get_custom_settings():
    host = custom_host_var.get().strip() or "smtp.example.com"
    try:
        port = int(custom_port_var.get().strip())
    except Exception:
        port = 587
    ssl_enabled = custom_ssl_var.get()
    starttls_enabled = custom_starttls_var.get()
    if ssl_enabled and starttls_enabled:
        # sécurité : prioriser SSL et désactiver STARTTLS
        starttls_enabled = False
    return (host, port, ssl_enabled, starttls_enabled)

def smtp_connect_and_login(host, port, user, password, ssl_enabled, starttls_enabled, timeout=10):
    if ssl_enabled and starttls_enabled:
        raise ValueError("ssl_enabled et starttls_enabled ne peuvent pas être tous les deux True.")

    if ssl_enabled:
        context = ssl.create_default_context()
        server = smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
        server.ehlo()
    else:
        server = smtplib.SMTP(host, port, timeout=timeout)
        server.ehlo()
        if starttls_enabled:
            context = ssl.create_default_context()
            server.starttls(context=context)
            server.ehlo()

    server.login(user, password)
    return server

def test_connection_action():
    provider = smtp_provider.get()
    if provider == "Custom":
        host, port, ssl_enabled, starttls_enabled = get_custom_settings()
    else:
        host, port, ssl_enabled, starttls_enabled = get_smtp_settings(provider)

    user = email_var.get().strip()
    pwd = password_entry.get()
    clear_messages()
    append_message("Test de la connexion en cours...", status="info")
    try:
        server = smtp_connect_and_login(host, port, user, pwd, ssl_enabled, starttls_enabled)
        server.quit()
        append_message("Connexion réussie ✅", status="success")
        append_details(f"Connexion test: {host}:{port} (ssl={ssl_enabled}, starttls={starttls_enabled})")
    except Exception as e:
        append_message("Échec de la connexion ❌", status="error")
        append_details(f"smtp_connect_and_login error: {repr(e)}")
        messagebox.showerror("Erreur", "Échec de la connexion SMTP. Voir les détails techniques.")

def send_test_email_action():
    provider = smtp_provider.get()
    if provider == "Custom":
        host, port, ssl_enabled, starttls_enabled = get_custom_settings()
    else:
        host, port, ssl_enabled, starttls_enabled = get_smtp_settings(provider)

    user = email_var.get().strip()
    pwd = password_entry.get()
    to_addr = dest_var.get().strip()

    clear_messages()
    if not user or not pwd or not to_addr:
        append_message("Remplissez email, mot de passe et destinataire.", status="error")
        return

    append_message("Envoi de l'email de test en cours...", status="info")
    try:
        server = smtp_connect_and_login(host, port, user, pwd, ssl_enabled, starttls_enabled)
        msg = MIMEText("Ceci est un email de test envoyé depuis SMTP Tester.")
        msg["From"] = user
        msg["To"] = to_addr
        msg["Subject"] = "Test SMTP - SMTP Tester"

        server.sendmail(user, [to_addr], msg.as_string())
        server.quit()
        append_message(f"Email envoyé ✅ à {to_addr}", status="success")
        append_details(f"Email envoyé depuis {user} via {host}:{port} (ssl={ssl_enabled}, starttls={starttls_enabled})")
    except Exception as e:
        append_message("Échec de l'envoi ❌", status="error")
        append_details(f"send_test_email error: {repr(e)}")
        messagebox.showerror("Erreur", "Échec lors de l'envoi de l'email. Voir les détails techniques.")

# -------------------------
# Interface graphique
# -------------------------
root = tk.Tk()
root.title("SMTP Tester — Modern UI")
root.geometry("920x560")
root.minsize(920, 560)
root.configure(bg="#F4F6F8")

root.columnconfigure(0, weight=1, uniform="a")
root.columnconfigure(1, weight=1, uniform="a")
root.rowconfigure(0, weight=1)

style = ttk.Style()
style.configure("Card.TFrame", background="white", relief="solid", borderwidth=1)
style.configure("TLabel", background="#F4F6F8", font=("Segoe UI", 10))
style.configure("TButton", font=("Segoe UI", 10))

# ----- Left card (config SMTP) -----
left_card = ttk.Frame(root, style="Card.TFrame", padding=12)
left_card.grid(row=0, column=0, padx=12, pady=12, sticky="nsew")
left_card.columnconfigure(0, weight=1)

tk.Label(left_card, text="Configuration SMTP", bg="white", font=("Segoe UI", 11, "bold")).grid(row=0, column=0, sticky="w", pady=(0,6))

smtp_provider = tk.StringVar(value="Gmail")
provider_combo = ttk.Combobox(left_card, textvariable=smtp_provider, values=["Gmail", "Office365", "Custom"], state="readonly")
provider_combo.grid(row=1, column=0, sticky="ew", pady=(0,10))

# ----- Custom configuration frame (masqué sauf si Custom) -----
custom_frame = ttk.Frame(left_card, style="Card.TFrame", padding=8)
custom_frame.grid(row=2, column=0, sticky="nsew")
custom_frame.columnconfigure(0, weight=1)

custom_host_var = tk.StringVar(value="smtp.example.com")
custom_port_var = tk.StringVar(value="587")
custom_ssl_var = tk.BooleanVar(value=False)
custom_starttls_var = tk.BooleanVar(value=True)

tk.Label(custom_frame, text="Configuration personnalisée", bg="white", font=("Segoe UI", 10, "bold")).grid(row=0, column=0, sticky="w", pady=(0,6))
tk.Label(custom_frame, text="Host :", bg="white").grid(row=1, column=0, sticky="w")
tk.Entry(custom_frame, textvariable=custom_host_var, width=30).grid(row=2, column=0, sticky="ew", pady=(0,6))

tk.Label(custom_frame, text="Port :", bg="white").grid(row=3, column=0, sticky="w")
tk.Entry(custom_frame, textvariable=custom_port_var, width=10).grid(row=4, column=0, sticky="w", pady=(0,6))

ssl_chk = tk.Checkbutton(custom_frame, text="SSL (ex: port 465)", variable=custom_ssl_var, bg="white", anchor="w")
ssl_chk.grid(row=5, column=0, sticky="w")
starttls_chk = tk.Checkbutton(custom_frame, text="STARTTLS (ex: port 587)", variable=custom_starttls_var, bg="white", anchor="w")
starttls_chk.grid(row=6, column=0, sticky="w", pady=(0,6))

def _on_custom_ssl_toggle():
    if custom_ssl_var.get():
        custom_starttls_var.set(False)
        # Optionnel : autoremplir port 465
        custom_port_var.set("465")

def _on_custom_starttls_toggle():
    if custom_starttls_var.get():
        custom_ssl_var.set(False)
        # Optionnel : autoremplir port 587
        custom_port_var.set("587")

custom_ssl_var.trace_add("write", lambda *a: _on_custom_ssl_toggle())
custom_starttls_var.trace_add("write", lambda *a: _on_custom_starttls_toggle())

def update_custom_visibility(event=None):
    sel = smtp_provider.get()
    if sel == "Custom":
        custom_frame.grid()
    else:
        custom_frame.grid_remove()
    if sel == "Gmail":
        custom_host_var.set("smtp.gmail.com")
        custom_port_var.set("587")
        custom_ssl_var.set(False)
        custom_starttls_var.set(True)
    elif sel == "Office365":
        custom_host_var.set("smtp.office365.com")
        custom_port_var.set("587")
        custom_ssl_var.set(False)
        custom_starttls_var.set(True)

provider_combo.bind("<<ComboboxSelected>>", update_custom_visibility)
if smtp_provider.get() != "Custom":
    custom_frame.grid_remove()

tk.Label(custom_frame, text="(Remplissez ces champs uniquement si 'Custom')", bg="white", fg="gray").grid(row=7, column=0, sticky="w", pady=(6,0))

# ----- Right card (authentification) -----
right_card = ttk.Frame(root, style="Card.TFrame", padding=12)
right_card.grid(row=0, column=1, padx=12, pady=12, sticky="nsew")
right_card.columnconfigure(0, weight=1)

tk.Label(right_card, text="Authentification", bg="white", font=("Segoe UI", 11, "bold")).grid(row=0, column=0, sticky="w", pady=(0,6))

tk.Label(right_card, text="Adresse email :").grid(row=1, column=0, sticky="w")
email_var = tk.StringVar(value="")
email_entry = ttk.Entry(right_card, textvariable=email_var, width=40)
email_entry.grid(row=2, column=0, sticky="ew", pady=3)

tk.Label(right_card, text="Mot de passe / App Password :").grid(row=3, column=0, sticky="w", pady=(6,0))
pass_frame = ttk.Frame(right_card)
pass_frame.grid(row=4, column=0, sticky="ew", pady=3)
pass_frame.columnconfigure(0, weight=1)

password_entry = ttk.Entry(pass_frame, width=40, show="•")
password_entry.grid(row=0, column=0, sticky="ew")
eye_label = tk.Label(pass_frame, text="👁", relief="flat", cursor="hand2", bg="white")
eye_label.grid(row=0, column=1, padx=(6,0))
eye_label.bind("<ButtonPress-1>", lambda e: password_entry.config(show=""))
eye_label.bind("<ButtonRelease-1>", lambda e: password_entry.config(show="•"))
eye_label.bind("<Leave>", lambda e: password_entry.config(show="•"))

tk.Label(right_card, text="Destinataire du test :").grid(row=5, column=0, sticky="w", pady=(8,0))
dest_var = tk.StringVar(value="")
dest_entry = ttk.Entry(right_card, textvariable=dest_var, width=40)
dest_entry.grid(row=6, column=0, sticky="ew", pady=3)

# ----- Boutons d'action -----
buttons_frame = tk.Frame(root, bg="#F4F6F8")
buttons_frame.grid(row=1, column=0, columnspan=2, sticky="ew", padx=12, pady=(0,6))
buttons_frame.columnconfigure(0, weight=1)
buttons_frame.columnconfigure(1, weight=1)

test_btn = tk.Button(buttons_frame, text="Tester la connexion", bg="#3498db", fg="white", relief="flat", command=test_connection_action)
test_btn.grid(row=0, column=0, sticky="ew", padx=(0,6), pady=8)

send_btn = tk.Button(buttons_frame, text="Envoyer un email test", bg="#2ecc71", fg="white", relief="flat", command=send_test_email_action)
send_btn.grid(row=0, column=1, sticky="ew", padx=(6,0), pady=8)

# ----- Messages / logs -----
msg_card = ttk.Frame(root, style="Card.TFrame", padding=10)
msg_card.grid(row=2, column=0, columnspan=2, sticky="ew", padx=12, pady=(0,12))
msg_card.columnconfigure(0, weight=1)

message_label = tk.Label(msg_card, text="", anchor="w", justify="left", bg="white", fg="black", font=("Segoe UI", 10))
message_label.grid(row=0, column=0, sticky="ew")

details_visible = False
details_label = tk.Label(msg_card, text="", anchor="nw", justify="left", bg="white", fg="gray", wraplength=880)
details_label.grid(row=2, column=0, sticky="ew", pady=(6,0))
details_label.grid_remove()

def toggle_details():
    global details_visible
    if details_visible:
        details_label.grid_remove()
        details_btn.config(text="Détails techniques ▼")
    else:
        details_label.grid()
        details_btn.config(text="Détails techniques ▲")
    details_visible = not details_visible

details_btn = tk.Button(msg_card, text="Détails techniques ▼", relief="flat", command=toggle_details)
details_btn.grid(row=1, column=0, sticky="w", pady=(6,0))

def append_message(text, status="info"):
    color = {"info":"#0d6efd", "success":"#2e7d32", "error":"#c62828"}.get(status, "#333")
    message_label.config(text=text, fg=color)

def append_details(text):
    prev = details_label.cget("text")
    new = prev + ("\n" if prev else "") + text
    details_label.config(text=new)

def clear_messages():
    message_label.config(text="")
    details_label.config(text="")

def copy_logs():
    combined = message_label.cget("text") + "\n" + details_label.cget("text")
    root.clipboard_clear()
    root.clipboard_append(combined)
    messagebox.showinfo("Copié", "Logs copiés dans le presse‑papier.")

copy_btn = tk.Button(root, text="Copier les logs", bg="#4CAF50", fg="white", relief="flat", command=copy_logs)
copy_btn.grid(row=3, column=0, columnspan=2, pady=(0,12))

def on_enter(event):
    test_connection_action()

root.bind("<Return>", on_enter)

# Affiche/masque la config custom selon la valeur initiale
update_custom_visibility()

root.mainloop()
