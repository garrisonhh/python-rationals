from setuptools import setup, find_packages

setup(
    name="rationals",
    version="0.1.2",
    packages=["rationals"],
    package_dir={"rationals": "rationals"},
    package_data={"rationals": ["**/*.so"]},
    include_package_data=True,
)
